import AppKit
import Combine
import QuartzCore
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
    /// 自测时关掉「别的 App 激活 → 收起」：离线基线跑在 LaunchServices 拉起的进程里，
    /// 期间任何一次别的 App 激活都会把展开态拍回闭合，导致抓到闭合帧。
    var appActivationCollapseEnabled = true
    /// 屏幕配置变化通知：只用来让几何缓存失效并重算让位。
    private var screenObserver: NSObjectProtocol?
    /// 焦点相关通知（诊断）：用来回答「面板有没有成为 key、失焦时有没有 resign」。
    private var focusObservers: [NSObjectProtocol] = []

    // MARK: - 诊断（只记录，不参与任何判定、计时与分支）

    /// 高频指针日志开关。
    ///
    /// `[POINTER]` / `[HOVER]` 实测约 11 行/秒（180 秒 2009 行），常开会淹掉真正有用的日志，
    /// 所以默认关闭，只在 `--pointer-log` 时输出。开合切换的 `[SHAPE]`（每次开合一两行）
    /// 属于低频，保留。
    static let pointerLogEnabled = CommandLine.arguments.contains("--pointer-log")

    /// 上一次判定看到的 inside，用来量「进/出」前一段停留了多久。
    private var diagLastInside = false
    /// 上一次 inside 变化的单调时钟（0 = 尚未记录）。
    private var diagInsideSince: CFTimeInterval = 0
    /// 开合切换的触发原因，只写进日志。
    private var diagStateReason = "-"
    private var diagStateObservation: AnyCancellable?

    convenience init(screen: NSScreen) {
        // 读屏一次并缓存（auxiliary 区只在缓存未命中时读）。
        self.init(metrics: NotchHardware.snapshot(for: screen).metrics)
    }

    init(metrics: ScreenGeometry.Metrics) {
        self.metrics = metrics

        // 顶部让位与矩形宽度同源：都从 NotchHardware 取，缓存命中时不再读屏。
        PageMetrics.configure(topInset: NotchHardware.topInset(for: metrics))
        let vm = NotchViewModel(
            closedSize: ScreenGeometry.closedSize(for: metrics),
            menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
        )
        // 硬件禁画区只有一个来源，视图靠它让位。
        vm.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: metrics)
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
            onDropFiles: { urls in relay.onDrop?(urls) },
            // 拖出结束：operation 由 `NSDraggingSource` 的会话回调给出，move 才删条目。
            onDragOutFile: { [weak vm] url, operation in
                vm?.applyShelfDragOut(url, operation: operation)
            }
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

        // 诊断：状态切换的那一帧打印形状与命中矩形；reason 由各调用点写入，只进日志。
        // `receive(on:)` 不能省：`@Published` 在 willSet 就发通知，订阅者读到的是**旧值**
        // （上一版日志里 open=0 实际对应的正是 closed→open）。切到主队列的下一轮读到的才是新值。
        diagStateObservation = vm.$state
            .map { $0 == .open }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let reason = self.diagStateReason
                self.diagStateReason = "-"
                self.logShapeTransition(reason)
            }

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
            .sink { [weak self, weak service] open in
                // 基线取证期间媒体已冻结：开合不能再触发 refresh，否则真实状态会盖掉夹具。
                guard self?.mediaFrozenForTesting != true else { return }
                service?.setPanelOpen(open)
            }
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

        // 启动诊断一行到底：真机验证时日志里必须能直接看到
        // 「硬件矩形 / 是否退化 / 徽标让位余量 / 窗口号」，否则截图与数值对不上。
        let box = NotchHardware.box(for: metrics)
        let badgeSlotWidth = vm.notchSize.width
        let badgeLeft = -badgeSlotWidth / 2 + vm.closedBadgeOffset + badgeSlotWidth
            - vm.closedBadgeTrailing - DesignSystem.Size.closedBadge
        // 与徽标同一坐标系（窗口水平中心为原点），否则两个数一个在屏幕坐标、
        // 一个在窗口坐标，差值没有意义。
        let hardwareRight = box.map { $0.rect.width / 2 } ?? 0
        NSLog(
            "[Brimio] HARDWARE rect=%@ estimated=%@ reason=%@ model=%@ window=%@ windowNumber=%d"
                + " badgeLeft=%.1f hardwareRight=%.1f badgeGap=%.1f topInset=%.1f",
            box.map { NSStringFromRect($0.rect) } ?? "nil(no-notch)",
            box.map { $0.isEstimated ? "true" : "false" } ?? "-",
            box?.reason ?? "-",
            NotchHardware.machineModel,
            NSStringFromRect(panel.frame),
            panel.windowNumber,
            badgeLeft,
            hardwareRight,
            badgeLeft - hardwareRight,
            PageMetrics.topInset
        )

        // 屏幕配置变化（换屏、改分辨率/缩放、菜单栏相关状态变化）：
        // 缓存失效并重算让位。窗口 frame 的重新定位不在本条范围内。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHardwareGeometry() }
        }

        // 焦点流转只观测、不改变行为：记录谁成为 key/main、什么时候 resign，
        // 以及 App 自己激活/失活。用在真机上判定「焦点环」与「失焦不收」的成因。
        let focusNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification
        ]
        focusObservers = focusNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { note in
                let window = note.object as? NSWindow
                NSLog("[FOCUS] notif %@ isKey=%d isMain=%d visible=%d",
                      note.name.rawValue,
                      (window?.isKeyWindow ?? false) ? 1 : 0,
                      (window?.isMainWindow ?? false) ? 1 : 0,
                      (window?.isVisible ?? false) ? 1 : 0)
            }
        }
        focusObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in NSLog("[FOCUS] app didResignActive") }
        )
        focusObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in NSLog("[FOCUS] app didBecomeActive") }
        )

        // 「失去焦点自动收起」的正确信号源。
        // 这个面板 canBecomeKey == false，永远不会成为 key，所以 windowDidResignKey
        // 这条路径不存在（实测一次都没触发）；能表达「焦点走了」的只有
        // 「别的 App 被激活」——它是非激活型面板唯一能观察到的失焦事件。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// 别的 App 被激活 → 视为「失焦」，收起展开态。
    /// 只改开合状态，不动窗口层级与焦点能力：面板依旧 `canBecomeKey == false`，
    /// 因此对键盘输入没有影响（本来也拿不到键盘焦点），点击响应同样不变。
    @objc private func activeApplicationChanged(_ note: Notification) {
        guard appActivationCollapseEnabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              viewModel.isOpen
        else { return }
        NSLog("[FOCUS] other app activated: %@ -> close", app.bundleIdentifier ?? "?")
        diagStateReason = "app-activate"
        viewModel.close()
    }

    /// 配置变化后重算硬件矩形与让位；缓存先失效，避免用到旧配置。
    func refreshHardwareGeometry() {
        NotchHardware.invalidateCache()
        guard let current = ScreenGeometry.current() else { return }
        PageMetrics.configure(topInset: NotchHardware.topInset(for: current.metrics))
        viewModel.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: current.metrics)
    }

    var windowForTesting: NotchPanel { panel }
    var viewModelForTesting: NotchViewModel { viewModel }
    var metricsForTesting: ScreenGeometry.Metrics { metrics }

    /// 功耗探针 / 基线取证用：停掉控制器自带的媒体服务，
    /// 否则它那条「播放中 2s 复核」会污染采样窗口；基线还要再挡住开合触发的刷新，
    /// 否则 `vm.open()` 那一刻的真实媒体会把夹具覆盖掉（首页高度随版式变，会直接量错高度）。
    private var mediaFrozenForTesting = false

    func stopMediaForTesting() {
        mediaFrozenForTesting = true
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

    /// 诊断：开合切换那一刻的形状尺寸与（inset 之后的）命中矩形，附触发原因。
    private func logShapeTransition(_ reason: String) {
        let rect = interactiveRect
        NSLog("[SHAPE] t=%.3f open=%d shape=%.1fx%.1f rect=(%.1f,%.1f %.1fx%.1f) reason=%@",
              CACurrentMediaTime(), viewModel.isOpen ? 1 : 0,
              viewModel.notchSize.width, viewModel.notchSize.height,
              rect.minX, rect.minY, rect.width, rect.height, reason as NSString)
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
        let mouse = NSEvent.mouseLocation
        let rect = interactiveRect
        let inside = rect.contains(mouse)
        // 命中判定的完整输入：指针位置、用于判定的矩形、当前形状尺寸与开合状态。
        // 有这四样才能判断「是不是拿动画中途的旧矩形去判新指针」。
        // t 是单调时钟（秒），用来量停留时长与两次判定之间的间隔。
        let now = CACurrentMediaTime()
        if Self.pointerLogEnabled {
            NSLog("[POINTER] t=%.3f mouse=(%.1f,%.1f) rect=(%.1f,%.1f %.1fx%.1f) inside=%d open=%d shape=%.1fx%.1f badgeTrail=%.1f pad=%.1f drag=%d",
                  now, mouse.x, mouse.y, rect.minX, rect.minY, rect.width, rect.height,
                  inside ? 1 : 0, viewModel.isOpen ? 1 : 0,
                  viewModel.notchSize.width, viewModel.notchSize.height,
                  viewModel.closedBadgeTrailing, hitPadding,
                  isFileDragInFlight ? 1 : 0)
        }

        // 诊断：记录进/出切换的那一帧，以及刚结束的那一段停留了多久。
        // 放在拖放分支之前：拖放分支会提前 return，放到后面就永远打不出来
        // （上一版 2442 条 [POINTER] / 0 条 [HOVER] 就是这么来的）。
        if inside != diagLastInside {
            let stayed = diagInsideSince == 0 ? 0 : now - diagInsideSince
            if Self.pointerLogEnabled {
                NSLog("[HOVER] t=%.3f inside %d->%d stayed=%.3f open=%d drag=%d", now,
                      diagLastInside ? 1 : 0, inside ? 1 : 0, stayed, viewModel.isOpen ? 1 : 0,
                      isFileDragInFlight ? 1 : 0)
            }
            diagLastInside = inside
            diagInsideSince = now
        }

        // 拖动会话的 pasteboard 带 fileURL、且左键确实按着，才算「文件拖动」。
        // 鼠标事件不在需要授权的类别里，这里不会触发任何隐私弹窗。
        if isFileDragInFlight {
            if inside { beginFileDrag() } else { endFileDrag() }
            return
        }
        if fileDragActive { endFileDrag() }
        handlePointer(inside: inside)
    }

    /// 当前是否真有一次文件拖动在进行。
    ///
    /// 两个条件缺一不可：
    /// 1. 左键正按着（`NSEvent.pressedMouseButtons` 第 0 位，不需要任何授权）；
    /// 2. 拖动会话的 pasteboard 带 `.fileURL`。
    ///
    /// 为什么必须加第 1 条：`NSPasteboard(name: .drag)` 是**常驻**的拖拽板，
    /// 一次拖动结束后里面的 fileURL 不会被清掉。只看类型的话，只要用户拖过一次文件，
    /// 这个属性就永久为真，`evaluatePointer()` 每次都在拖放分支提前 return，
    /// 悬停计时（0.3s）从来没有被执行过。
    /// runtime-c 的证据：2442 条 `[POINTER]` 里 `[HOVER]` 0 条，
    /// `interactive=` 的 17 次进出全部由这里驱动——不是全局监听收不到事件，
    /// 而是事件都被这个分支吃掉了。
    private var isFileDragInFlight: Bool {
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return false }
        return NSPasteboard(name: .drag).types?.contains(.fileURL) == true
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
                self.diagStateReason = "hover"
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
                self.diagStateReason = "leave"
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
        diagStateObservation?.cancel()
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
