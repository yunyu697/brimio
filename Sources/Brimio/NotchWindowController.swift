import AppKit
import Combine
import SwiftUI

/// 窗口控制器：建窗、定位、指针跟踪、开合调度。
///
/// 这里的鼠标策略是「显式穿透」：
/// - 窗口固定 640×210，透明区域默认 `ignoresMouseEvents = true`，点击直接落到下层 App；
/// - 只有指针进入当前状态的可交互矩形（闭合=刘海矩形，展开=展开矩形）时才关闭穿透；
/// - 开合由全局 + 本地 mouseMoved 监听驱动，带进入/离开延时。
@MainActor
final class NotchWindowController {
    /// 几何输入。生产路径来自 `NSScreen`，selftest 可以注入固定值（无屏 runner）。
    private let metrics: ScreenGeometry.Metrics
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    /// 媒体服务：事件驱动读 AppleScript，结果推回 viewModel。
    private let mediaService: MediaService
    private var mediaSubscription: AnyCancellable?
    /// 播放器兼容设置窗口：面板高度放不下完整说明，单独一扇窗。
    private let playerSettings: PlayerSettingsWindowController

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var pendingOpen: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?
    private var pointerInside = false
    /// 外部文件拖动进行中：拖动期间不因悬停展开，松手后立刻恢复穿透。
    private var fileDragActive = false
    private var pointerInsideBeforeFileDrag = false
    /// 根视图建得比面板早，drop 回调要靠这层中转拿到 self。
    private let dropRelay: FileDropRelay

    // hover 延时：进入 0.3s 防误触（指针只是扫过屏幕顶部时不展开），离开 0.1s 防抖（短暂越界不收起）。
    private let hoverDelay: TimeInterval = 0.3
    private let leaveDelay: TimeInterval = 0.1
    /// 命中矩形外扩。
    /// 闭合态窗口穿透时 SwiftUI 拿不到 hover，命中入口只能靠全局 mouseMoved 监听；
    /// 留 6pt 余量避免贴边抖动。
    private let hitPadding: CGFloat = 6
    /// 自测时关掉真实指针监听，避免和程序化调用互相覆盖。
    var pointerTrackingEnabled = true

    convenience init(screen: NSScreen) {
        self.init(metrics: ScreenGeometry.Metrics.from(screen))
    }

    init(metrics: ScreenGeometry.Metrics) {
        self.metrics = metrics

        let vm = NotchViewModel(
            closedSize: ScreenGeometry.closedSize(for: metrics),
            menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
        )
        self.viewModel = vm

        // MediaService 只在这里建一次：面板开合驱动它的低频校正，
        // 它的状态变化推回 vm（闭包在主线程回调）。
        let service = MediaService()
        self.mediaService = service
        service.onChange = { [weak vm] snapshot, permission in
            vm?.applyMedia(snapshot, permission: permission)
        }

        // 设置窗口在 init 里先建好（不带 self 捕获，避免初始化顺序问题）。
        let settingsWindow = PlayerSettingsWindowController()
        self.playerSettings = settingsWindow

        // drop 回调要走中转：此时 self 还不能被捕获，panel 也还没建。
        let relay = FileDropRelay()

        let rootView = NotchRootView(
            vm: vm,
            onTap: { [weak vm] in vm?.open() },
            onSelect: { [weak vm] item in vm?.select(item) },
            onMediaControl: { [weak service] control in service?.perform(control) },
            onOpenPlayerSettings: { [weak vm, weak service, weak settingsWindow] in
                guard let vm else { return }
                settingsWindow?.show(vm: vm) { bundleID, enabled in
                    // 开关只写偏好；未开启的播放器在 `refreshPresence` 的闸门处被直接丢掉。
                    PlayerRegistry.setEnabled(enabled, for: bundleID)
                    vm.reloadPlayerSettings()
                    service?.refreshPresence()
                }
            },
            // 拖放回调只经过中转，不在这里捕获 self（此时 panel 还没建）。
            onDropFiles: { urls in relay.onDrop?(urls) }
        )
        let hostingView = NotchHostingView(rootView: rootView)
        let frame = ScreenGeometry.windowFrame(for: metrics)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]

        self.panel = NotchPanel(contentRect: frame, contentView: hostingView)
        self.dropRelay = relay
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        installMonitors()

        // 松手：加进文件架 → 展开并切到文件架页 → 结束拖动会话。
        dropRelay.onDrop = { [weak self, weak vm] urls in
            guard let vm else { return }
            vm.addShelfFiles(urls)
            vm.open()
            vm.select(.files)
            self?.endFileDrag()
        }

        // 只在展开时开 5s 低频校正，收起即停表（`MediaService.setPanelOpen`）。
        mediaSubscription = vm.$state
            .map { $0 == .open }
            .removeDuplicates()
            .sink { [weak service] open in service?.setPanelOpen(open) }
        service.start()

        NSLog(
            "[Brimio] window frame=%@ contentLayout=%@ content=%@ safeAreaTop=%.1f closed=%@ menuBar=%.1f chin=%.1f screen=%@",
            NSStringFromRect(panel.frame),
            NSStringFromRect(panel.contentLayoutRect),
            NSStringFromRect(hostingView.frame),
            hostingView.safeAreaInsets.top,
            NSStringFromSize(vm.closedSize),
            ScreenGeometry.menuBarHeight(for: metrics),
            vm.chinHeight,
            metrics.name
        )
    }

    var windowForTesting: NotchPanel { panel }
    var viewModelForTesting: NotchViewModel { viewModel }
    var metricsForTesting: ScreenGeometry.Metrics { metrics }

    /// 功耗探针用：停掉控制器自带的媒体服务，
    /// 否则它那条「播放中 2s 复核」会污染采样窗口。
    func stopMediaForTesting() {
        mediaService.stop()
    }

    /// 当前状态下允许接收鼠标事件的矩形（屏幕坐标）。
    ///
    /// 用**形状矩形**（`viewModel.notchSize`：闭合 183×32 / 展开按当前页内容决定），
    /// 而不是固定的窗口矩形——窗口是 312×200 的画布，比形状大得多，
    /// 用窗口矩形会让面板外一圈空白也吃鼠标事件。
    private var interactiveRect: NSRect {
        let base = ScreenGeometry.rectAtTopCenter(size: viewModel.notchSize, on: metrics)
        // 闭合态缩略图只向右加宽：形状中心随之右移，命中矩形也得跟着移，
        // 否则缩略图那一块看得见但点不到。
        let shifted = base.offsetBy(dx: viewModel.closedBadgeOffset, dy: 0)
        return shifted.insetBy(dx: -hitPadding, dy: -hitPadding)
    }

    private func installMonitors() {
        // `leftMouseUp` 只为拖放收尾：拖动结束的那一刻要把穿透恢复回去。
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp
        ]

        // 指针在其他 App 上时由全局监听兜底。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluatePointer() }
        }

        // 指针落在本窗口上时，全局监听收不到，用本地监听补齐。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.evaluatePointer() }
            return event
        }
    }

    private func evaluatePointer() {
        guard pointerTrackingEnabled else { return }
        let inside = interactiveRect.contains(NSEvent.mouseLocation)

        // 拖动会话的 pasteboard 带 fileURL 时才算「文件拖动」。
        // 鼠标事件不在需要授权的类别里，这里不会触发任何隐私弹窗。
        if isFileDragInFlight {
            if inside { beginFileDrag() } else { endFileDrag() }
            return
        }
        if fileDragActive { endFileDrag() }
        handlePointer(inside: inside)
    }

    /// 拖动中的剪贴板是否带文件 URL（拖动会话专用 pasteboard）。
    private var isFileDragInFlight: Bool {
        NSPasteboard(name: .drag).types?.contains(.fileURL) == true
    }

    /// 文件拖到刘海上：临时接收 drop，并抑制悬停展开。
    ///
    /// 闭合窗口平时 `ignoresMouseEvents = true`（不吞摄像头区域的点击），
    /// 但 drop 必须由窗口自己接，所以只在拖动期间打开命中，松手立即恢复。
    func beginFileDrag() {
        guard !fileDragActive else { return }
        fileDragActive = true
        pendingOpen?.cancel()
        pendingOpen = nil
        pendingClose?.cancel()
        pendingClose = nil
        pointerInsideBeforeFileDrag = pointerInside
        pointerInside = true
        viewModel.setFileDragTarget(true)
        panel.setInteractive(true)
    }

    func endFileDrag() {
        guard fileDragActive else { return }
        fileDragActive = false
        viewModel.setFileDragTarget(false)
        // 已经展开（松手后展开到文件架页）时保持可交互，交给正常进出逻辑。
        guard !viewModel.isOpen else { return }
        pointerInside = pointerInsideBeforeFileDrag
        if !pointerInside { panel.setInteractive(false) }
    }

    /// 指针进出可交互矩形的统一入口；自测时直接调用它。
    func handlePointer(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside

        if inside {
            pendingClose?.cancel()
            pendingClose = nil
            // 先把窗口变成可交互，否则接下来的点击会穿透到下层。
            panel.setInteractive(true)

            guard !viewModel.isOpen else { return }
            pendingOpen?.cancel()
            pendingOpen = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.hoverDelay * 1_000_000_000))
                guard !Task.isCancelled, self.pointerInside else { return }
                self.viewModel.open()
                NSLog("[Brimio] hover -> open")
            }
        } else {
            pendingOpen?.cancel()
            pendingOpen = nil

            guard viewModel.isOpen else {
                panel.setInteractive(false)
                return
            }

            pendingClose?.cancel()
            pendingClose = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.leaveDelay * 1_000_000_000))
                guard !Task.isCancelled, !self.pointerInside else { return }
                self.viewModel.close()
                self.panel.setInteractive(false)
                NSLog("[Brimio] leave -> closed")
            }
        }
    }

    func shutdown() {
        pendingOpen?.cancel()
        pendingClose?.cancel()
        mediaSubscription?.cancel()
        mediaService.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel.orderOut(nil)
    }
}

/// drop 回调的中转：根视图在 `panel` 之前创建，不能直接捕获 self。
@MainActor
final class FileDropRelay {
    var onDrop: (([URL]) -> Void)?
}
