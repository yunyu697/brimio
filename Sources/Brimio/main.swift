import AppKit
import CoreGraphics
import Darwin
import SwiftUI

/// 无屏几何注入。
///
/// `--headless-geometry=1512x982,inset=32,menubar=32,auxl=666.5,auxr=666.5`
/// 或环境变量 `BRIMIO_HEADLESS_GEOMETRY`（CI 用前者，便于在日志里看到实参）。
/// 只有显式给出时 `ScreenGeometry.injected` 才非空；生产路径永远从 `NSScreen` 取。
enum HeadlessGeometry {
    static let flagPrefix = "--headless-geometry="
    static let envKey = "BRIMIO_HEADLESS_GEOMETRY"

    static func rawSpec(_ args: [String]) -> String? {
        let fromArgs = args.compactMap { arg -> String? in
            guard arg.hasPrefix(flagPrefix) else { return nil }
            return String(arg.dropFirst(flagPrefix.count))
        }.last
        if let fromArgs, !fromArgs.isEmpty { return fromArgs }
        if let fromEnv = ProcessInfo.processInfo.environment[envKey], !fromEnv.isEmpty { return fromEnv }
        return nil
    }

    static func metrics(from spec: String) -> ScreenGeometry.Metrics? {
        var width: CGFloat = 1512
        var height: CGFloat = 982
        var inset: CGFloat = 32
        var menuBar: CGFloat = 32
        var auxLeft: CGFloat?
        var auxRight: CGFloat?
        var sawSize = false

        for rawPart in spec.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.contains("x"), !part.contains("=") {
                let wh = part.split(separator: "x")
                guard wh.count == 2, let w = Double(wh[0]), let h = Double(wh[1]), w > 0, h > 0 else {
                    return nil
                }
                width = CGFloat(w)
                height = CGFloat(h)
                sawSize = true
            } else if let eq = part.firstIndex(of: "=") {
                let key = String(part[..<eq])
                guard let value = Double(part[part.index(after: eq)...]) else { return nil }
                switch key {
                case "inset": inset = CGFloat(value)
                case "menubar": menuBar = CGFloat(value)
                case "auxl": auxLeft = CGFloat(value)
                case "auxr": auxRight = CGFloat(value)
                default: return nil
                }
            } else {
                return nil
            }
        }
        guard sawSize else { return nil }

        return ScreenGeometry.Metrics(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrameMaxY: height - menuBar,
            safeAreaTop: inset,
            auxLeftWidth: auxLeft,
            auxRightWidth: auxRight,
            name: "injected \(Int(width))x\(Int(height))"
        )
    }
}

/// 本轮期望的几何来源。由启动参数决定，`--selftest` 里断言实际来源与它一致，
/// 避免「加了 flag 但代码仍走 NSScreen」这种假绿。
var expectedGeometrySource = "NSScreen"

/// 无屏注入下**确实无法验证**的项。只在 source=injected 时打印，不做静默跳过：
/// 这些断言在真实有屏机器上照常执行（同一个二进制、同一套断言）。
let headlessUncovered: [String] = [
    "NSScreen 的真实读数：safeAreaInsets.top / auxiliaryTopLeftArea / auxiliaryTopRightArea 用注入值代替，只验证算法不验证真机",
    "真实窗口层级与跨屏跟随（屏参变化、热插拔、全屏 App 下的层序）",
    "真实指针位置相关的采样：hover 进入/离开、拖放悬停、⌘ 拖出（--e2e / --animate-probe 不在本模式运行）",
    "屏幕录制与视觉复核（--render / --shadow-probe / --shoulder-probe 需要真实屏）",
    "菜单栏自动隐藏状态下的信号：不修改用户系统设置，故未实测；若该状态下 auxiliary 双区变 nil，会走保守收缩（内容偏窄，但不会压硬件）",
]

/// AppKit 生命周期入口（不使用 SwiftUI App，避免非 bundle 可执行文件的启动差异）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 固定路径日志：`open -n` 启动时 stdout/stderr 会被 LaunchServices 丢掉，
        // 把 stderr（NSLog 也走这里）重定向到文件，真机验证时可直接读取。
        if let logPath = flagValue("--log-file=") {
            freopen(logPath, "a", stderr)
            setvbuf(stderr, nil, _IOLBF, 0)
        }
        // 几何注入只影响 selftest；其余模式仍然要求真实屏幕。
        if let spec = HeadlessGeometry.rawSpec(CommandLine.arguments) {
            guard let metrics = HeadlessGeometry.metrics(from: spec) else {
                print("[SELFTEST] FAIL 无法解析 --headless-geometry=\(spec)")
                exit(1)
            }
            ScreenGeometry.injected = metrics
            expectedGeometrySource = "injected"
            print("[SELFTEST] geometry spec=\(spec)")
        }

        // selftest：几何可注入，因此不强制要求物理屏。
        if CommandLine.arguments.contains("--selftest") {
            guard let geometry = ScreenGeometry.current() else {
                print("[SELFTEST] FAIL no screen and no injected geometry")
                exit(1)
            }
            print("[SELFTEST] geometry source=\(geometry.source) name=\(geometry.metrics.name)")
            controller = NotchWindowController(metrics: geometry.metrics)
            runSelfTest()
            return
        }

        // 原始屏幕信号：只打印系统给的原值，不做任何加工，用来确定刘海矩形的可信来源。
        if CommandLine.arguments.contains("--screen-signals") {
            printScreenSignals()
            exit(0)
        }

        // 几何探针：不依赖物理屏。注入屏幕与刘海参数，离屏画出闭合态与展开态，
        // 并在同一坐标系里叠一条「硬件禁画区」标注，用来判定真机遮挡属于哪种参数组合。
        if let spec = flagValue("--render-geometry=") {
            runGeometryProbe(
                spec: spec,
                outputDirectory: flagValue("--render-out=") ?? NSTemporaryDirectory(),
                label: flagValue("--label=") ?? "geometry"
            )
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSLog("[Brimio] no screen available")
            NSApp.terminate(nil)
            return
        }
        // 离屏渲染/探针不建窗口，也要先按真实屏幕注入顶部让位，否则形状高度按默认内边距算。
        PageMetrics.configure(topInset: NotchHardware.topInset(for: ScreenGeometry.Metrics.from(screen)))

        // 离屏渲染模式：不创建真实窗口，避免闪一下。
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            renderSnapshots(to: CommandLine.arguments[index + 1], screen: screen)
            return
        }

        // 阴影像素探针：渲染不带红线的干净图，逐像素量侧边/顶边/底部阴影。
        if let index = CommandLine.arguments.firstIndex(of: "--shadow-probe") {
            let dir = CommandLine.arguments.count > index + 1 && !CommandLine.arguments[index + 1].hasPrefix("--")
                ? CommandLine.arguments[index + 1] : nil
            runShadowProbe(screen: screen, outputDirectory: dir)
            return
        }

        // 功耗探针不建窗口：窗口/ SwiftUI 合成本身有固定唤醒，会把 2s 复核表的差异淹掉。
        // 这里只跑被测组件（MediaService + CoreAudio 监听），组件的唤醒代价才可归因。
        if CommandLine.arguments.contains("--power-probe") {
            runPowerProbe()
            return
        }

        controller = NotchWindowController(screen: screen)

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        } else if CommandLine.arguments.contains("--e2e") {
            runEndToEndHoverTest()
        } else if CommandLine.arguments.contains("--show-open") {
            // 便于截图/肉眼检查：启动后直接展开并保持。
            Task { @MainActor [weak controller] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                controller?.viewModelForTesting.open()
                NSLog("[Brimio] show-open -> open")
            }
        } else if CommandLine.arguments.contains("--media-probe") {
            runMediaProbe()
        } else if CommandLine.arguments.contains("--presence-probe") {
            runPresenceProbe()
        } else if let captureDir = flagValue("--capture-demo=") {
            runCaptureDemo(outputDirectory: captureDir)
        } else if CommandLine.arguments.contains("--window-probe") {
            runWindowProbe(screen: screen)
        } else if let baselineDir = flagValue("--render-baseline=") {
            runBaseline(outputDirectory: baselineDir, screen: screen)
        } else if CommandLine.arguments.contains("--render-baseline") {
            runBaseline(outputDirectory: "outputs/baseline", screen: screen)
        } else if CommandLine.arguments.contains("--shoulder-probe") {
            runShoulderProbe(screen: screen)
        } else if CommandLine.arguments.contains("--animate-probe") {
            #if DEBUG
            runAnimationProbe()
            #else
            print("[ANIM] --animate-probe 只在 DEBUG 构建可用（采样钩子被 #if DEBUG 隔离）")
            exit(1)
            #endif
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 自测：状态机 + 几何 + 穿透开关

    private func runSelfTest() {
        guard let controller else {
            print("[SELFTEST] FAIL: controller not created")
            exit(1)
        }

        Task { @MainActor in
            controller.pointerTrackingEnabled = false
            var failures: [String] = []
            var total = 0

            func check(_ condition: Bool, _ name: String, _ detail: String = "") {
                total += 1
                if condition {
                    print("[SELFTEST] PASS  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
                } else {
                    failures.append(name)
                    print("[SELFTEST] FAIL  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
                }
            }

            let panel = controller.windowForTesting
            let vm = controller.viewModelForTesting
            // 几何一律走注入值；真实屏幕只在 source=NSScreen 时存在。
            let metrics = controller.metricsForTesting
            let geometrySource = ScreenGeometry.injected == nil ? "NSScreen" : "injected"
            let screen: NSScreen? = geometrySource == "NSScreen" ? (NSScreen.main ?? NSScreen.screens.first) : nil
            let expected = ScreenGeometry.windowFrame(for: metrics)

            // 0. 几何来源：证明注入路径真的被走到（而不是加了 flag 仍读 NSScreen）。
            check(
                geometrySource == expectedGeometrySource,
                "geometry source is \(expectedGeometrySource)",
                "source=\(geometrySource) name=\(metrics.name) "
                    + "frame=\(Int(metrics.frame.width))x\(Int(metrics.frame.height)) "
                    + "inset=\(Int(metrics.safeAreaTop))"
            )

            // 1. 硬件禁画区：唯一来源是 NotchHardware，且必须与 auxiliary 反推一致。
            if let box = NotchHardware.box(for: metrics) {
                let derived = metrics.frame.width - (metrics.auxLeftWidth ?? 0) - (metrics.auxRightWidth ?? 0)
                check(
                    box.isEstimated ? true : abs(box.rect.width - derived) < 0.01,
                    "hardware rect matches auxiliary gap",
                    "width=\(box.rect.width) derived=\(derived) estimated=\(box.isEstimated)"
                )
                // 徽标：位置取视图真正用的 `closedBadgeTrailing`，
                // 按「形状右缘 − 内边距 − 徽标宽」换算到屏幕中心坐标系再比。
                let badgeVM = NotchViewModel(
                    closedSize: ScreenGeometry.closedSize(for: metrics),
                    menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
                )
                badgeVM.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: metrics)
                badgeVM.applyMedia(
                    MediaSnapshot(
                        title: "T", artist: "A", album: "B",
                        isPlaying: true, artwork: nil, source: .music
                    ),
                    permission: .granted
                )
                let slot = badgeVM.notchSize.width
                let badgeLeft = -slot / 2 + badgeVM.closedBadgeOffset + slot
                    - badgeVM.closedBadgeTrailing - DesignSystem.Size.closedBadge
                let hardwareRight = box.rect.maxX - metrics.frame.midX
                check(
                    badgeLeft - hardwareRight >= NotchHardware.contentGap - 0.01,
                    "closed badge clears hardware by \(NotchHardware.contentGap)pt",
                    String(
                        format: "badgeLeft=%+.1f hardwareRight=%+.1f gap=%+.1f estimated=%@",
                        badgeLeft, hardwareRight, badgeLeft - hardwareRight,
                        box.isEstimated ? "true" : "false"
                    )
                )
                // 展开态：整块内容（含 chrome 行）必须落在硬件矩形之下。
                // 这是展开态唯一的竖向让位规则，水平位置不再承担避让职责。
                check(
                    PageMetrics.topInset - box.rect.height >= NotchHardware.contentGap - 0.01,
                    "expanded content starts below the hardware band",
                    String(
                        format: "topInset=%.0f band=%.0f gap=%+.0f",
                        PageMetrics.topInset, box.rect.height, PageMetrics.topInset - box.rect.height
                    )
                )
            }

            // 1b. 缓存：同一屏幕配置只算一次；配置一变或显式失效必须重算。
            NotchHardware.invalidateCache()
            NotchHardware.resetCacheCounters()
            let firstBox = NotchHardware.box(for: metrics)
            _ = NotchHardware.box(for: metrics)
            check(
                NotchHardware.computeCount == 1,
                "hardware rect is computed once per screen config",
                "computeCount=\(NotchHardware.computeCount)"
            )
            var changedMetrics = metrics
            changedMetrics.safeAreaTop += 1
            _ = NotchHardware.box(for: changedMetrics)
            check(
                NotchHardware.computeCount == 2,
                "screen config change recomputes the rect",
                "computeCount=\(NotchHardware.computeCount)"
            )
            NotchHardware.invalidateCache()
            _ = NotchHardware.box(for: metrics)
            check(
                NotchHardware.computeCount == 3,
                "invalidation forces recompute",
                "computeCount=\(NotchHardware.computeCount)"
            )
            check(
                firstBox == NotchHardware.box(for: metrics),
                "same config yields the same rect"
            )

            // 1c. 四条形状断言之①③：两态共用同一条构造 + 凹角内必须透背景。
            //
            // ① 构造（不依赖数值）：顶部角的第一段是二次贝塞尔，起点 (0,0)、控制点 (t,0)、终点 (t,t)。
            //    这条与参照实现同构；t 是切点偏移，不是 cornerRadius。
            let constructionRect = CGRect(x: 0, y: 0, width: 300, height: 148)
            func shoulderQuad(t: CGFloat) -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
                let path = NotchShape(topTangentOffset: t, bottomTangentOffset: 24)
                    .path(in: constructionRect)
                var start: CGPoint?
                var quad: (control: CGPoint, end: CGPoint)?
                path.forEach { element in
                    switch element {
                    case .move(let point):
                        if start == nil { start = point }
                    case .quadCurve(let to, let control):
                        if quad == nil { quad = (control, to) }
                    default:
                        break
                    }
                }
                guard let start, let quad else { return nil }
                return (start, quad.control, quad.end)
            }
            let constructionOffsets = [
                ScreenGeometry.shoulderTangentOffset.closed,
                ScreenGeometry.shoulderTangentOffset.opened
            ]
            let constructionOK = constructionOffsets.allSatisfy { t in
                guard let quad = shoulderQuad(t: t) else { return false }
                return abs(quad.start.x) < 0.001 && abs(quad.start.y) < 0.001
                    && abs(quad.control.x - t) < 0.001 && abs(quad.control.y) < 0.001
                    && abs(quad.end.x - t) < 0.001 && abs(quad.end.y - t) < 0.001
            }
            check(
                constructionOK,
                "both states share one shoulder construction: control (t,0), end (t,t)",
                "t=" + constructionOffsets.map { String(format: "%.0f", $0) }.joined(separator: "/")
                    + "；起点 (0,0) 控点 (t,0) 终点 (t,t)"
            )

            // ③ 凹角内必须透背景（像素证据）。
            //   A 空耳 (x0 + 1, top + 1)          —— 两态都必须透出背景（亮度 > 0.4），方角会变黑
            //   B 实体 (x0 + t + 2, top + t + 2)  —— 必须是黑（亮度 ≤0.05）
            //   C y = top + t/2 的首个不透明像素必须落在 0.914t：
            //     内凹解析解 0.914t；外凸圆弧是 0.134t；方角是 0。三者互不重叠。
            // 采样点（离屏图 scale=3；形状左上角在画布 (40 + (窗口宽 − 形状宽)/2, 40)）。
            // 若 overscan 用矩形垫底填平两个空耳，A/C 会变黑 → 立刻红。
            for openState in [false, true] {
                let probeVM = NotchViewModel(
                    closedSize: ScreenGeometry.closedSize(for: metrics),
                    menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
                )
                probeVM.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: metrics)
                if openState { probeVM.open() }
                let shape = probeVM.notchSize
                let t = probeVM.topTangentOffset
                let tag = openState ? "open" : "closed"

                let canvas = ZStack(alignment: .topLeading) {
                    Color(red: 0.62, green: 0.64, blue: 0.67)
                    NotchRootView(
                        vm: probeVM,
                        onTap: {},
                        onSelect: { _ in },
                        onMediaControl: { _ in },
                        onOpenPlayerSettings: {},
                        onDropFiles: { _ in },
                        onDragOutFile: { _, _ in }
                    )
                    .frame(width: ScreenGeometry.windowSize.width, height: ScreenGeometry.windowSize.height)
                    .offset(x: 40, y: 40)
                }
                .frame(width: 720, height: 300)

                guard let rep = renderBitmap(canvas) else {
                    check(false, "\(tag) concave shoulder keeps the ear transparent", "渲染失败")
                    continue
                }
                let renderScale: CGFloat = 3
                let x0 = 40 + (ScreenGeometry.windowSize.width - shape.width) / 2
                let top: CGFloat = 40
                func lum(_ px: CGFloat, _ py: CGFloat) -> Double? {
                    guard let c = rep.colorAt(
                        x: Int((px * renderScale).rounded()),
                        y: Int((py * renderScale).rounded())
                    ) else { return nil }
                    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                }
                let ears = [lum(x0 + 1, top + 1), lum(x0 + shape.width - 1, top + 1)]
                let solids = [
                    lum(x0 + t + 2, top + t + 2),
                    lum(x0 + shape.width - t - 2, top + t + 2)
                ]
                let earsOK = ears.allSatisfy { ($0 ?? 0) > 0.4 }
                let solidDark = solids.allSatisfy { ($0 ?? 1) < 0.05 }
                // 首黑扫描：y = top + t/2，从 x0−3 往右扫。
                var firstOffset: Double = -1
                let scanY = top + t / 2
                var scanX = Int(((x0 - 3) * renderScale).rounded())
                let scanEnd = Int(((x0 + t + 3) * renderScale).rounded())
                while scanX <= scanEnd {
                    if let c = rep.colorAt(x: scanX, y: Int((scanY * renderScale).rounded())),
                       let s = c.usingColorSpace(.sRGB) {
                        let sr: Double = Double(s.redComponent)
                        let sg: Double = Double(s.greenComponent)
                        let sb: Double = Double(s.blueComponent)
                        let value: Double = 0.299 * sr + 0.587 * sg + 0.114 * sb
                        if s.alphaComponent > 0.99 && value < 0.05 {
                            firstOffset = Double(scanX) / Double(renderScale) - Double(x0)
                            break
                        }
                    }
                    scanX += 1
                }
                let analytic = 0.914 * Double(t)
                let concave = firstOffset >= 0 && abs(firstOffset - analytic) <= 0.6
                check(
                    earsOK && solidDark && concave,
                    "\(tag) concave shoulder: ear transparent, first opaque at 0.914t (t=\(Int(t))pt)",
                    String(
                        format: "ear=%.2f/%.2f solid=%.2f/%.2f firstOpaque=+%.2f 期望+%.2f（外凸+%.2f）shape=%.0fx%.0f",
                        ears[0] ?? -1, ears[1] ?? -1,
                        solids[0] ?? -1, solids[1] ?? -1,
                        firstOffset, analytic, 0.134 * Double(t),
                        shape.width, shape.height
                    )
                )
            }

            // 2. 窗口存在且在屏幕顶部
            check(panel.isVisible, "window is visible")
            check(
                panel.frame.size == ScreenGeometry.windowSize,
                "window size is fixed \(Int(ScreenGeometry.windowSize.width))x\(Int(ScreenGeometry.windowSize.height))",
                "\(panel.frame.size)"
            )
            check(
                ScreenGeometry.windowSize.width > ScreenGeometry.maxOpenSize.width,
                "window wider than largest page (room for spring overshoot)",
                "window=\(Int(ScreenGeometry.windowSize.width)) maxPage=\(Int(ScreenGeometry.maxOpenSize.width))"
            )
            check(panel.frame.maxY == metrics.frame.maxY, "window top aligned with screen top", "maxY=\(panel.frame.maxY)")
            check(
                abs(panel.frame.midX - metrics.frame.midX) < 0.5,
                "window horizontally centered",
                "midX=\(panel.frame.midX)"
            )
            check(panel.frame == expected, "window frame matches geometry")
            check(panel.level == .mainMenu + 3, "window level above menu bar", "level=\(panel.level.rawValue)")
            check(
                panel.collectionBehavior.contains(.canJoinAllSpaces)
                    && panel.collectionBehavior.contains(.fullScreenAuxiliary),
                "joins all spaces and full-screen auxiliary",
                "raw=\(panel.collectionBehavior.rawValue)"
            )

            // 2. WindowServer 视角：窗口确实在屏幕上
            //
            // 此前这条断言被放宽成「相等或等比缩放 0.85~1.01」，等于给 9.5% 的尺寸偏差
            // 发了长期通行证。`--window-probe` 查清：`window.frame` 一直是固定尺寸，
            // 变的是**坐标空间**——本机 CGWindowList 的全局空间里，整块桌面被等比缩小并居中
            // （桌面 1324×862 @ (73,47)，而 display bounds 是 1470×956），
            // 0ms/100ms/500ms/1s/3s 五个时刻完全一致，且不带 hud/utility 样式的对照窗口数值相同，
            // 所以既不是启动瞬时值，也与面板样式无关。
            //
            // 于是断言改成严格版本：
            // a) 与「同 frame、无面板样式」的对照窗口在合成器里必须完全相等（0 容差）；
            // b) 换算到 CG 空间后与 frame 严格对齐（容差 2.5pt：实测残差 1.6pt，来自合成器
            //    对每条边各自取整，同一台机器上稳定）。
            //
            // 这一段依赖真实屏幕（坐标空间换算需要 NSScreen），注入模式下显式标为「本环境不覆盖」，
            // 打印出来，而不是静默当作通过。
            if let screen {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let onScreen = onScreenWindowBounds(pid: getpid())
                for info in onScreenWindowInfo(pid: getpid()) {
                    print(
                        "[SELFTEST] window-info layer=\(info[kCGWindowLayer as String] ?? "-")"
                            + " alpha=\(info[kCGWindowAlpha as String] ?? "-")"
                            + " bounds=\(info[kCGWindowBounds as String] ?? "-")"
                    )
                }
                check(onScreen.count == 1, "window registered on screen", "count=\(onScreen.count)")
                if let bounds = onScreen.first {
                    let control = referenceWindow(panel.frame)
                    let mapper = await cgSpaceMapper(for: screen)
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    let controlBounds = cgWindowBounds(for: control)
                    control.orderOut(nil)

                    if let controlBounds {
                        check(
                            bounds == controlBounds,
                            "panel composites exactly like a plain window of the same frame",
                            "panel=\(bounds) control=\(controlBounds)"
                        )
                    }
                    if let mapper {
                        print("[SELFTEST] cg-space \(mapper.summary)")
                        let mapped = mapper.map(panel.frame)
                        let residual = max(
                            abs(bounds.minX - mapped.minX), abs(bounds.minY - mapped.minY),
                            abs(bounds.width - mapped.width), abs(bounds.height - mapped.height)
                        )
                        check(
                            residual <= 2.5,
                            "on-screen bounds equal window frame mapped into CG space",
                            String(format: "bounds=%.1fx%.1f@(%.1f,%.1f) mapped=%.1fx%.1f@(%.1f,%.1f) residual=%.2fpt",
                                   bounds.width, bounds.height, bounds.minX, bounds.minY,
                                   mapped.width, mapped.height, mapped.minX, mapped.minY, residual)
                        )
                        let mappedScreen = mapper.map(screen.frame)
                        check(
                            abs(bounds.minY - mappedScreen.minY) <= 1
                                && abs(bounds.midX - mappedScreen.midX) <= 2,
                            "on-screen bounds touch screen top",
                            String(format: "minY=%.1f top=%.1f midX=%.1f center=%.1f",
                                   bounds.minY, mappedScreen.minY, bounds.midX, mappedScreen.midX)
                        )
                    }
                }
            } else {
                print("[SELFTEST] UNCOVERED  WindowServer 注册 / CG 坐标空间对齐（source=injected，无真实屏幕）")
            }

            // 3. 初始穿透
            check(panel.ignoresMouseEvents, "collapsed window ignores mouse events")
            check(!vm.isOpen, "initial state is closed")
            // 四条形状断言之②：两态取值来源=参照实现（闭合 6 / 展开 19），**不是实测**。
            // 6→6 标定成立的前提（见 ScreenGeometry.shoulderTangentOffset）：
            //   同一构造（①）+ 同一窗口侧口径（宽=硬件带+4、闭合高=safeAreaInsets.top、顶边贴屏顶）。
            // 本机硬件带 179×32 → 闭合 183×32；参照闭合高就是 safeAreaInsets.top，所以高度关系也同口径。
            let safeTop = ScreenGeometry.current()?.metrics.safeAreaTop ?? 32
            let closedShoulder = vm.topTangentOffset
            check(
                closedShoulder == ScreenGeometry.shoulderTangentOffset.closed
                    && closedShoulder == 6,
                "closed shoulder tangent offset = reference 6",
                String(format: "closed=%.0f 参照闭合=6；闭合宽 %.0f（硬件带 179+4）、高 %.0f = safeAreaTop %.0f",
                       closedShoulder, ScreenGeometry.closedSize(for: metrics).width,
                       ScreenGeometry.closedSize(for: metrics).height, safeTop)
            )

            // 闭合态的内容左右内缩：t 6 + 净间隙 4 = 10（闭合没有页面内容，这里只做布局口径）。
            let closedContentInset = vm.contentHorizontalInset

            // 4. 指针进入 -> 延时展开
            controller.handlePointer(inside: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            check(vm.isOpen, "hover opens the notch")
            check(!panel.ignoresMouseEvents, "open window receives mouse events")
            check(vm.notchSize == PageMetrics.shapeSize(for: .home, home: .empty),
                  "open size follows home page content")
            check(panel.frame.size == ScreenGeometry.windowSize, "window frame unchanged after open")
            // ②（续）：展开态取参照的 19，不要求与闭合同值——同族是构造相同，不是数值相同。
            check(
                vm.topTangentOffset == ScreenGeometry.shoulderTangentOffset.opened
                    && vm.topTangentOffset == 19,
                "open shoulder tangent offset = reference 19 (same dimension, 6→6 calibrated)",
                String(format: "open=%.0f 参照展开=19；比值 %.2f，参照 19/6=%.2f；绝对值均未实测",
                       vm.topTangentOffset, vm.topTangentOffset / closedShoulder, 19.0 / 6.0)
            )

            // ④ top 同时驱动「内容左右内缩」与「顶部 1pt 遮缝条横向内缩」：
            //   内缩 = t + NotchHardware.contentGap(4) → 闭合 10 / 展开 23。
            //   内容盒因此始终在侧壁内侧（旧实现固定 16，展开 t=19 时被裁 3pt）。
            let insetClosed = ScreenGeometry.contentInsetExpectation(isOpen: false)
            let insetOpen = ScreenGeometry.contentInsetExpectation(isOpen: true)
            check(
                closedContentInset == 10 && vm.contentHorizontalInset == 23
                    && vm.contentHorizontalInset - vm.topTangentOffset == NotchHardware.contentGap,
                "top-driven content inset: closed 10 / open 23 (= t + 4pt gap)",
                String(format: "闭合 %.0f = %.0f+%.0f；展开 %.0f = %.0f+%.0f；遮缝条同步 %.0f/%.0f",
                       closedContentInset, insetClosed, NotchHardware.contentGap,
                       vm.contentHorizontalInset, insetOpen, NotchHardware.contentGap,
                       insetClosed, insetOpen)
            )

            // 底部：bottom 仍取 24，t=19 后侧壁与底边直线段是否还够（不够才需要把 bottom 也纳入状态驱动）。
            //   侧壁 = height − t − bottom；底边直线段 = width − 2×bottom。
            let openSizes = ExpandedItem.allCases.map {
                PageMetrics.shapeSize(for: $0, shelfCount: PageMetrics.overflowShelfCount)
            }
            let minWall = openSizes.map { $0.height - 19 - 24 }.min() ?? 0
            let minBottomStraight = openSizes.map { $0.width - 24 * 2 }.min() ?? 0
            check(
                minWall > 0 && minBottomStraight > 0,
                "bottom stays 24: vertical wall and bottom straight are still positive",
                String(format: "侧壁最小 %.0fpt（= 高 − 19 − 24）；底边直线段最小 %.0fpt（= 宽 − 48）；不需要状态驱动",
                       minWall, minBottomStraight)
            )

            // 竖向预算：top + bottom 必须严格小于面板高度，否则上/下切角互相吃、直边变负。
            let closedInsets = ScreenGeometry.cornerRadiusInsets.closed
            let closedHeight = ScreenGeometry.closedSize(for: metrics).height
            let closedBudget = closedInsets.top + closedInsets.bottom
            check(
                closedBudget < closedHeight,
                "closed vertical budget: top + bottom < panel height",
                String(format: "%.0f + %.0f = %.0f < %.0f（余量 %.0fpt）",
                       closedInsets.top, closedInsets.bottom, closedBudget, closedHeight,
                       closedHeight - closedBudget)
            )
            let openInsets = ScreenGeometry.cornerRadiusInsets.opened
            let openHeight = openSizes.map(\.height).min() ?? 0
            let openHeightMax = openSizes.map(\.height).max() ?? 0
            let openBudget = openInsets.top + openInsets.bottom
            check(
                openBudget < openHeight,
                "open vertical budget: top + bottom < panel height",
                String(format: "%.0f + %.0f = %.0f < 最小页高 %.0f（最大页高 %.0f，余量 %.0fpt）",
                       openInsets.top, openInsets.bottom, openBudget, openHeight, openHeightMax,
                       openHeight - openBudget)
            )

            // 4b. 分页路由：三页都能到达；切页不改开合状态，尺寸跟着页面内容走
            check(vm.route == .home, "default route is home")
            var visited: [ExpandedItem] = []
            for item in ExpandedItem.allCases {
                vm.select(item)
                if vm.route == item { visited.append(item) }
            }
            check(
                visited.count == ExpandedItem.allCases.count,
                "every tab reachable",
                visited.map(\.title).joined(separator: ",")
            )
            let homeSize = PageMetrics.shapeSize(for: .home, home: .empty)
            let sizeKeys = ExpandedItem.allCases.map { "\($0.shapeSize.width)x\($0.shapeSize.height)" }
            check(
                Set(sizeKeys).count == ExpandedItem.allCases.count,
                "pages have distinct sizes",
                ExpandedItem.allCases.map { "\($0.title)=\(Int($0.shapeSize.width))x\(Int($0.shapeSize.height))" }
                    .joined(separator: " ")
            )
            // 高度必须严格等于「顶部让位 + chrome + 间距 + 内容自然高 + 底部 padding」：
            // 一旦某页被下限/中间档夹住，这个等式就不成立。
            let padding = PageMetrics.contentPadding
            let topInset = PageMetrics.topInset
            let fixedChrome = PageMetrics.chromeHeight + PageMetrics.rowSpacing
            let horizontalInset = PageMetrics.openContentHorizontalInset
            let paddingMath = ExpandedItem.allCases.allSatisfy { item in
                let shape = PageMetrics.shapeSize(for: item)
                return abs(shape.width - (item.contentSize.width + horizontalInset * 2)) < 0.001
                    && abs(shape.height - (item.contentSize.height + fixedChrome + topInset + padding)) < 0.001
            }
            check(
                paddingMath,
                "panel height = top inset + chrome + spacing + content + bottom padding",
                ExpandedItem.allCases.map {
                    "\($0.title) 内容\(Int($0.contentSize.width))x\(Int($0.contentSize.height))"
                        + " + 左右\(Int(horizontalInset))"
                        + " + 顶部\(Int(topInset)) + chrome\(Int(PageMetrics.chromeHeight))"
                        + " + 间距\(Int(PageMetrics.rowSpacing)) + 底部\(Int(padding))"
                        + " = \(Int($0.shapeSize.width))x\(Int($0.shapeSize.height))"
                }.joined(separator: "；")
            )
            check(
                PageMetrics.chromeHeight <= DesignSystem.Control.md,
                "chrome is at most one 28pt row",
                "chrome=\(Int(PageMetrics.chromeHeight))pt"
            )
            // 高度预算拆成三个互不重叠的桶：实际内容块 / chrome / padding+间距。
            // 三个占比的分母都是面板总高，相加必须是 100%（旧口径把 chrome 与
            // 底部 padding 都算进「内容区」，所以会同时报出 80.6% 和 chrome 19.4%）。
            let budgetMath = ExpandedItem.allCases.allSatisfy { item in
                let b = PageMetrics.heightBudget(for: item)
                return abs(b.total - item.shapeSize.height) < 0.001
            }
            check(
                budgetMath,
                "content + chrome + padding+间距 equals panel height",
                ExpandedItem.allCases.map {
                    let b = PageMetrics.heightBudget(for: $0)
                    return "\($0.title) \(Int(b.content))+\(Int(b.chrome))+\(Int(b.overhead))"
                        + "=\(Int(b.total))"
                }.joined(separator: "；")
            )
            // 闭合态缩略图只向右长：无曲目不占宽，有曲目加宽 28pt 且位移半个增量。
            let badgeVM = NotchViewModel(closedSize: vm.closedSize, menuBarHeight: vm.menuBarHeight)
            let closedWidth = badgeVM.notchSize.width
            let hiddenOffset = badgeVM.closedBadgeOffset
            badgeVM.applyMedia(
                MediaSnapshot(
                    title: "T", artist: "A", album: "B",
                    isPlaying: true, artwork: nil, source: .music
                ),
                permission: .granted
            )
            let badgeExtra = badgeVM.notchSize.width - closedWidth
            check(
                badgeVM.media.hasTrack
                    && badgeExtra == DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm
                    && hiddenOffset == 0
                    && badgeVM.closedBadgeOffset == badgeExtra / 2,
                "closed media badge widens to the right only",
                "closed=\(Int(closedWidth)) badge=\(Int(closedWidth + badgeExtra))"
                    + " offset=\(badgeVM.closedBadgeOffset) hiddenOffset=\(hiddenOffset)"
            )
            // IOPM 通道只有状态没有曲目：同样走右侧加宽槽位（放应用图标），闭合态不放文字。
            let presenceVM = NotchViewModel(closedSize: vm.closedSize, menuBarHeight: vm.menuBarHeight)
            let presenceWidth = presenceVM.notchSize.width
            presenceVM.applyMedia(
                .presence(bundleID: "com.netease.163music", appName: "网易云音乐", isMusicPlayer: true),
                permission: .granted
            )
            let presenceExtra = presenceVM.notchSize.width - presenceWidth
            check(
                presenceVM.showsClosedBadge
                    && presenceExtra == DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm
                    && presenceVM.closedBadgeOffset == presenceExtra / 2,
                "presence-only uses the right badge slot (never centered text)",
                "width=\(Int(presenceVM.notchSize.width)) extra=\(presenceExtra)"
                    + " offset=\(presenceVM.closedBadgeOffset)"
            )
            // 暂停 / App 退出 / 没有会话：IOPM 没信号时闭合态什么都不显示。
            let idleVM = NotchViewModel(closedSize: vm.closedSize, menuBarHeight: vm.menuBarHeight)
            idleVM.applyMedia(.none, permission: .granted)
            check(
                idleVM.showsClosedBadge == false
                    && idleVM.notchSize.width == idleVM.closedSize.width,
                "no audio process leaves the closed notch untouched",
                "width=\(Int(idleVM.notchSize.width)) badge=false"
            )
            // 网页视频 / 微信语音也会命中 IOPM，但闭合态不该为之点亮。
            let browserVM = NotchViewModel(closedSize: vm.closedSize, menuBarHeight: vm.menuBarHeight)
            let browserWidth = browserVM.notchSize.width
            browserVM.applyMedia(
                .presence(bundleID: "com.google.Chrome", appName: "Google Chrome", isMusicPlayer: false),
                permission: .granted
            )
            check(
                browserVM.showsClosedBadge == false
                    && browserVM.notchSize.width == browserWidth,
                "non-music audio process keeps the closed notch quiet",
                "bundle=com.google.Chrome badge=false width=\(Int(browserVM.notchSize.width))"
            )
            let ratiosSumToOne = ExpandedItem.allCases.allSatisfy { item in
                let b = PageMetrics.heightBudget(for: item)
                return abs(b.contentRatio + b.chromeRatio + b.overheadRatio + b.clearanceRatio - 1) < 1e-9
            }
            check(
                ratiosSumToOne,
                "the four height shares sum to 100%",
                ExpandedItem.allCases.map {
                    let b = PageMetrics.heightBudget(for: $0)
                    return String(
                        format: "%@ 内容%.1f%% / chrome %.1f%% / padding+间距 %.1f%% / 系统让位 %.1f%%",
                        $0.title, b.contentRatio * 100, b.chromeRatio * 100,
                        b.overheadRatio * 100, b.clearanceRatio * 100
                    )
                }.joined(separator: "；")
            )
            // 首页是媒体页：实际内容块必须比「我们可控的两块」（自有留白、chrome）都大，
            // 否则说明 chrome 或留白又比内容还占地方。
            // 系统让位（刘海硬件带）单列，不计入这条比较：它不是设计选择。
            let homeBudget = PageMetrics.heightBudget(for: .home)
            check(
                homeBudget.content > homeBudget.chrome && homeBudget.content > homeBudget.overhead,
                "home content block beats the padding and chrome it pays for",
                String(
                    format: "内容 %d > 自有留白 %d、chrome %d（另加系统让位 %d）",
                    Int(homeBudget.content), Int(homeBudget.overhead),
                    Int(homeBudget.chrome), Int(homeBudget.clearance)
                )
            )
            // 份额门禁分两种口径：内容 ≥ 60pt 的页面比 30%，更小的页面比「固定开销 92 不随内容增长」。
            // 报告按真实比较结果输出「达标 / 不达标」，不无条件印「≥ 下限」。
            for item in ExpandedItem.allCases {
                print("[SHARE] \(PageMetrics.contentShareReport(for: item))")
            }
            let belowFloor = ExpandedItem.allCases.filter { !PageMetrics.contentShareVerdict(for: $0).passes }
            check(
                belowFloor.isEmpty,
                "every page passes its content rule (30% floor for content ≥ 60pt, fixed overhead below)",
                ExpandedItem.allCases.map { PageMetrics.contentShareReport(for: $0) }.joined(separator: "；")
            )
            // 规范 §7.2 高度表：每个可区分布局态都必须落在表内，期望值写死。
            let specHeights: [(name: String, size: CGSize)] = [
                ("home.playing", PageMetrics.shapeSize(for: .home, home: .playing)),
                ("home.presenceOnly", PageMetrics.shapeSize(for: .home, home: .presenceOnly)),
                ("home.permissionDenied", PageMetrics.shapeSize(for: .home, home: .permissionDenied)),
                ("home.empty", PageMetrics.shapeSize(for: .home, home: .empty)),
                ("players.0", PageMetrics.shapeSize(for: .players, playersEnabled: 0)),
                ("players.1", PageMetrics.shapeSize(for: .players, playersEnabled: 1)),
                ("players.2", PageMetrics.shapeSize(for: .players, playersEnabled: 2)),
            ]
            let expectedHeights: [String: CGFloat] = [
                "home.playing": 148, "home.presenceOnly": 120, "home.permissionDenied": 120,
                "home.empty": 107, "players.0": 166, "players.1": 194, "players.2": 222,
            ]
            let heightTableOK = specHeights.allSatisfy { expectedHeights[$0.name] == $0.size.height }
            check(
                heightTableOK,
                "sub-state heights match SPEC §7.2 (148/120/120/107, 166/194/222)",
                specHeights.map { "\($0.name)=\(Int($0.size.height))" }.joined(separator: " ")
            )
            // H = 92 + C：C 只按行高求和，没有声明槽位/Spacer/比例分配。
            let contentHeights: [String: CGFloat] = [
                "home.playing": PageMetrics.homeContentHeight(.playing),
                "home.presenceOnly": PageMetrics.homeContentHeight(.presenceOnly),
                "home.permissionDenied": PageMetrics.homeContentHeight(.permissionDenied),
                "home.empty": PageMetrics.homeContentHeight(.empty),
                "players.0": PageMetrics.playersContentHeight(enabledCount: 0),
                "players.1": PageMetrics.playersContentHeight(enabledCount: 1),
                "players.2": PageMetrics.playersContentHeight(enabledCount: 2),
            ]
            let heightFormulaOK = specHeights.allSatisfy { entry in
                guard let content = contentHeights[entry.name] else { return false }
                return abs(entry.size.height - (PageMetrics.fixedOverhead + content)) < 0.001
            }
            check(
                heightFormulaOK && PageMetrics.fixedOverhead == 92,
                "H = 92 + C for every sub-state",
                specHeights.map { entry in
                    "\(entry.name): \(Int(entry.size.height)) = 92 + \(Int(contentHeights[entry.name] ?? -1))"
                }.joined(separator: "；")
            )
            // 内容盒 23 由骨架注入一次；设置页按钮是整行持久填充面，再内缩 4 → 27、宽 246。
            let fillInset = DesignSystem.Spacing.xs
            let settingsButtonWidth = ExpandedItem.players.contentSize.width - fillInset * 2
            check(
                PageMetrics.openContentHorizontalInset == 23
                    && PageMetrics.openContentHorizontalInset + fillInset == 27
                    && settingsButtonWidth == 246,
                "settings button fill face is inset 4 inside the 23pt content box (246 @ 27)",
                "内容盒=\(Int(PageMetrics.openContentHorizontalInset)) 填充面=\(Int(PageMetrics.openContentHorizontalInset + fillInset))"
                    + " 宽=\(Int(settingsButtonWidth))"
            )
            // 文案表档位：两处真实文案都是单行档 → 122 这一档当前不可达（不是漏测）。
            check(
                HomeCopyTable.emptyLines == 1 && HomeCopyTable.deniedLines == 1,
                "home copy table declares single-line tiers (107 / 120); 122 reserved for a declared 2-line tier",
                "emptyLines=\(HomeCopyTable.emptyLines) deniedLines=\(HomeCopyTable.deniedLines)"
            )
            vm.select(.files)
            check(vm.isOpen, "switching tab keeps the notch open")
            check(
                vm.notchSize == PageMetrics.shapeSize(for: .files),
                "size follows the selected page",
                "\(vm.notchSize)"
            )
            check(panel.frame.size == ScreenGeometry.windowSize, "window frame unchanged after tab switch")
            vm.select(.home)
            check(vm.notchSize == homeSize, "size returns to home page", "\(vm.notchSize)")

            // 5. 指针离开 -> 延时收起
            controller.handlePointer(inside: false)
            try? await Task.sleep(nanoseconds: 600_000_000)
            check(!vm.isOpen, "leaving closes the notch")
            check(panel.ignoresMouseEvents, "closed window ignores mouse events again")
            // 收起后的尺寸回到闭合档：高度必须等于闭合高度，宽度最多是「闭合 + 一枚徽标」
            // （有播放会话时右侧会留出 28pt 的徽标槽位，所以不能直接比 closedSize）。
            check(
                vm.notchSize.height == vm.closedSize.height
                    && vm.notchSize.width
                        <= vm.closedSize.width + DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm,
                "closed size restored",
                "\(vm.notchSize) closed=\(vm.closedSize)"
            )
            check(panel.frame.size == ScreenGeometry.windowSize, "window frame unchanged after close")

            // 6. 文件架：五个状态各自断言尺寸与份额（不能只测空架）
            //
            // 尺寸表来自 DESIGN.md：空架/1 条 124，2 条 164，3 条 204，≥4 条 232（视口 140）。
            // 逐状态打印，方便和文档表格逐行核对。
            let shelfStates: [(count: Int, height: CGFloat)] = [
                (0, 124), (1, 124), (2, 164), (3, 204), (4, 232)
            ]
            var shelfStateLines: [String] = []
            var shelfStatesPass = true
            for state in shelfStates {
                let shape = PageMetrics.shapeSize(for: .files, shelfCount: state.count)
                let verdict = PageMetrics.contentShareVerdict(for: .files, shelfCount: state.count)
                let ok = shape.height == state.height && shape.width == 248 && verdict.passes
                shelfStatesPass = shelfStatesPass && ok
                let line = String(
                    format: "%d 条 -> %.0fx%.0f 内容 %.0f/%.0f %.1f%%%@",
                    state.count, shape.width, shape.height,
                    verdict.content, verdict.total, verdict.ratio * 100,
                    ok ? "" : " FAIL"
                )
                shelfStateLines.append(line)
                print("[SHELF] \(line)")
            }
            check(
                shelfStatesPass,
                "file shelf holds its size and content rule in all five states",
                shelfStateLines.joined(separator: "；")
            )
            check(
                PageMetrics.maxSize.height == 232,
                "panel height cap stays at 232pt",
                "\(Int(PageMetrics.maxSize.height))pt"
            )
            // 文件架的高度必须真的跟着条目数走：否则上面五条会一起退化成同一个值。
            let shelfHeights = shelfStates.map {
                PageMetrics.shapeSize(for: .files, shelfCount: $0.count).height
            }
            check(
                shelfHeights == [124, 124, 164, 204, 232],
                "file shelf height is derived from the entry count",
                shelfHeights.map { "\(Int($0))" }.joined(separator: " / ")
            )

            // 7. 文件架数据：置顶、去重、移除、move 死链、外部删除、清空
            let shelfDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-shelf-selftest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
            func makeShelfFile(_ name: String, bytes: Int64) -> URL {
                let url = shelfDir.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.truncate(atOffset: UInt64(bytes))
                    try? handle.close()
                }
                return url
            }
            let fileA = makeShelfFile("报告.pdf", bytes: 36_000)
            let fileB = makeShelfFile("截图.png", bytes: 1_400_000)
            let fileC = makeShelfFile("素材.zip", bytes: 900)

            let added = vm.addShelfFiles([fileA, fileB, fileC])
            check(
                added == 3 && vm.shelfItems.map(\.name) == ["报告.pdf", "截图.png", "素材.zip"],
                "new files are prepended and counted",
                "added=\(added) order=\(vm.shelfItems.map(\.name))"
            )
            check(
                vm.shelfItems.map(\.formattedSize) == ["35 KB", "1.3 MB", "900 B"],
                "size string is fixed-width and locale-independent",
                vm.shelfItems.map(\.formattedSize).joined(separator: " / ")
            )
            _ = vm.addShelfFiles([fileA])
            check(
                vm.shelfItems.count == 3 && vm.shelfItems.first?.name == "报告.pdf",
                "dropping the same path again moves it to the top without duplicating",
                vm.shelfItems.map(\.name).joined(separator: " / ")
            )
            vm.removeShelfFile(vm.shelfItems[1])
            check(
                vm.shelfItems.map(\.name) == ["报告.pdf", "素材.zip"],
                "removing one entry keeps the others",
                vm.shelfItems.map(\.name).joined(separator: " / ")
            )
            // move 到别处：原路径失效，条目必须在同一次操作里消失。
            let movedDir = shelfDir.appendingPathComponent("moved", isDirectory: true)
            try? FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(
                at: fileA,
                to: movedDir.appendingPathComponent(fileA.lastPathComponent)
            )
            vm.applyShelfDragOut(fileA, operation: .move)
            check(
                !vm.shelfItems.contains { $0.name == "报告.pdf" },
                "moving an entry out removes it immediately",
                vm.shelfItems.map(\.name).joined(separator: " / ")
            )
            // 外部删除：下一次用户动作（这里显式调用 pruneShelf）触发移除。
            try? FileManager.default.removeItem(at: fileC)
            let pruned = vm.pruneShelf()
            check(
                pruned == ["素材.zip"] && vm.shelfItems.isEmpty,
                "deleting outside the app removes the entry on the next user action",
                "pruned=\(pruned) remaining=\(vm.shelfItems.count)"
            )
            // copy 拖出不改变原路径 → 条目保留；清空只移除引用。
            let fileD = makeShelfFile("备注.txt", bytes: 120)
            _ = vm.addShelfFiles([fileD])
            vm.applyShelfDragOut(fileD, operation: .copy)
            check(
                vm.shelfItems.count == 1 && FileManager.default.fileExists(atPath: fileD.path),
                "copy drag keeps the entry and the original file",
                "items=\(vm.shelfItems.count)"
            )

            // 7b. 拖出源：只写 .fileURL；会话结束的 operation 决定条目去留。
            // 拖出不走 SwiftUI `.onDrag`（拿不到结束时的 move/copy），
            // 这里断言的是 `NSDraggingSource` 直接调用的那个出口。
            let dragOutFile = makeShelfFile("拖出.txt", bytes: 256)
            _ = vm.addShelfFiles([dragOutFile])
            let dragItem = FileShelfDragOutHandle.pasteboardItem(for: dragOutFile)
            check(
                dragItem.types == [.fileURL]
                    && dragItem.string(forType: .fileURL) == dragOutFile.absoluteString,
                "drag-out offers only .fileURL (same type as drag-in)",
                "types=\(dragItem.types.map(\.rawValue)) value=\(dragItem.string(forType: .fileURL) ?? "-")"
            )
            let dragSource = ShelfDragOutSource(url: dragOutFile) { operation in
                vm.applyShelfDragOut(dragOutFile, operation: operation)
            }
            check(
                ShelfDragOutSource.operations(for: []) == [.copy]
                    && ShelfDragOutSource.operations(for: .command) == [.move],
                "drag-out defaults to copy and allows move only with Command",
                "none=\(ShelfDragOutSource.operations(for: []).rawValue)"
                    + " command=\(ShelfDragOutSource.operations(for: .command).rawValue)"
            )
            dragSource.finished(operation: .copy)
            check(
                vm.shelfItems.contains { $0.url.path == dragOutFile.path }
                    && FileManager.default.fileExists(atPath: dragOutFile.path),
                "copy drag-out keeps the entry",
                "items=\(vm.shelfItems.count)"
            )
            dragSource.finished(operation: .move)
            check(
                !vm.shelfItems.contains { $0.url.path == dragOutFile.path },
                "move drag-out removes the entry immediately",
                vm.shelfItems.map(\.name).joined(separator: " / ")
            )

            // 7c. 拖动期间整窗可交互：透明边缘上的 drop 必须被形状路径挡掉，
            // 拖入自动滚动只在视口上下 1/2 行内走一行。
            let closedShape = NotchShape(
                topTangentOffset: ScreenGeometry.cornerRadiusInsets.closed.top,
                bottomTangentOffset: ScreenGeometry.cornerRadiusInsets.closed.bottom
            )
            let closedRect = CGRect(origin: .zero, size: ScreenGeometry.closedSize(for: metrics))
            let shapeGuard: (CGPoint) -> Bool = { closedShape.contains($0, in: closedRect) }
            let cornerPoint = CGPoint(x: 1, y: 1)
            let centerPoint = CGPoint(x: closedRect.midX, y: closedRect.midY)
            check(
                !FileDropDelegate.accepts(hasFileURL: true, location: cornerPoint, shapeContains: shapeGuard)
                    && FileDropDelegate.accepts(hasFileURL: true, location: centerPoint, shapeContains: shapeGuard)
                    && !FileDropDelegate.accepts(hasFileURL: false, location: centerPoint, shapeContains: nil),
                "drop is accepted only inside the notch path and only for .fileURL",
                "corner(1,1)=\(shapeGuard(cornerPoint) ? "inside" : "outside")"
                    + " center(\(Int(centerPoint.x)),\(Int(centerPoint.y)))=\(shapeGuard(centerPoint) ? "inside" : "outside")"
            )
            let viewport = FileShelfLayout.viewportHeight
            let scrollSteps = [
                FileShelfLayout.autoScrollStep(localY: viewport - 1, viewportHeight: viewport, currentIndex: 0, count: 4),
                FileShelfLayout.autoScrollStep(localY: 1, viewportHeight: viewport, currentIndex: 2, count: 4),
                FileShelfLayout.autoScrollStep(localY: viewport / 2, viewportHeight: viewport, currentIndex: 1, count: 4),
                FileShelfLayout.autoScrollStep(localY: viewport - 1, viewportHeight: viewport, currentIndex: 3, count: 4),
                FileShelfLayout.autoScrollStep(localY: 1, viewportHeight: viewport, currentIndex: 0, count: 4)
            ]
            check(
                scrollSteps == [1, 1, nil, nil, nil],
                "drag auto-scroll steps one row at the viewport edges only",
                scrollSteps.map { $0.map(String.init) ?? "nil" }.joined(separator: ",")
            )

            vm.clearShelf()
            check(vm.shelfItems.isEmpty, "clearing removes references only")

            // 8. 闭合态拖放：三条验收（API 级，直接驱动控制器状态机）
            check(!vm.isOpen && panel.ignoresMouseEvents, "precondition: closed and pass-through")
            controller.beginFileDrag()
            check(
                !panel.ignoresMouseEvents,
                "file drag over the closed notch accepts the drop",
                "ignoresMouseEvents=\(panel.ignoresMouseEvents)"
            )
            try? await Task.sleep(nanoseconds: 450_000_000)
            check(
                !vm.isOpen,
                "hovering during a file drag does not expand the notch",
                "open=\(vm.isOpen) after 0.45s (hoverDelay=0.3s)"
            )
            controller.endFileDrag()
            check(panel.ignoresMouseEvents, "drag end restores pass-through")
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(
                panel.ignoresMouseEvents,
                "pass-through still on 200ms after the drag ends"
            )


            // 9. 界面规范静态检查：视图层不允许出现裸的字号/行高/间距/圆角/颜色
            //
            // 扫描是**递归**的：`Generated/` 之类的子目录不能靠「不在扫描范围」逃过检查，
            // 要豁免必须用相对路径写进 DesignLint.exemptions 并说明原因。
            let lint = DesignLint.scanUI()
            for violation in lint.violations {
                print("[LINT] \(violation)")
            }
            print("[LINT] discovered \(lint.discoveredFiles.count) file(s): \(lint.discoveredFiles.joined(separator: ", "))")
            print("[LINT] checked \(lint.checkedFiles.count) file(s): \(lint.checkedFiles.joined(separator: ", "))")
            for name in lint.exemptedFiles {
                let reason = DesignLint.exemptions.first { $0.path == name }?.reason ?? ""
                print("[LINT] exempt \(name)：\(reason)")
            }
            check(
                lint.discoveredFiles.count == DesignLint.expectedDiscoveredFileCount,
                "lint discovers every swift file recursively (subdirectories included)",
                "\(lint.discoveredFiles.count)/\(DesignLint.expectedDiscoveredFileCount) discovered"
            )
            check(
                lint.checkedFiles.count == DesignLint.expectedCheckedFileCount,
                "lint checks discovered files minus explicit exemptions",
                "\(lint.checkedFiles.count)/\(DesignLint.expectedCheckedFileCount) checked, "
                    + "\(lint.exemptedFiles.count) exempt"
            )
            check(
                lint.discoveredFiles.contains("Generated/Naming.swift")
                    && lint.exemptedFiles.contains("Generated/Naming.swift"),
                "generated file in a subdirectory is reached by path, not by being out of scope",
                "Generated/Naming.swift"
            )
            check(
                lint.violations.isEmpty,
                "view layer uses only DesignSystem tokens",
                lint.violations.isEmpty ? "\(lint.checkedFiles.count) file(s) clean" : "\(lint.violations.count) violation(s)"
            )
            // 「偷偷缩字号」的红线：全仓（含豁免文件）minimumScaleFactor 必须为零。
            let scaleHits = DesignLint.minimumScaleFactorHits()
            check(
                scaleHits.isEmpty,
                "minimumScaleFactor is gone from every source file (exemptions included)",
                scaleHits.isEmpty ? "0 hit(s)" : scaleHits.joined(separator: " | ")
            )
            check(
                DesignLint.horizontalInsetWhitelist.allSatisfy { !$0.reason.isEmpty },
                "every horizontal-inset exemption states a reason",
                DesignLint.horizontalInsetWhitelist
                    .map { "\($0.path)：\($0.reason)" }.joined(separator: "；")
            )
            // 负向用例：递归必须真的生效，三条新规则必须真的会命中。
            // 临时目录里造 `Views/FakeView.swift`（含裸数值 + minimumScaleFactor），
            // 若扫描退回「只列顶层目录」，这个文件根本不会被发现，这条就会 FAIL。
            let probeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lint-recursive-probe-\(UUID().uuidString)", isDirectory: true)
            let probeSub = probeRoot.appendingPathComponent("Views", isDirectory: true)
            try? FileManager.default.createDirectory(at: probeSub, withIntermediateDirectories: true)
            let probeScaleCall = "." + "minimumScale" + "Factor" + "(0.9)"
            let probeSource = """
            struct FakeView: View {
                var body: some View {
                    Text("x")
                        \(probeScaleCall)
                        .padding(.horizontal, 8)
                        .font(.system(size: 12))
                }
            }
            """
            try? probeSource.write(
                to: probeSub.appendingPathComponent("FakeView.swift"),
                atomically: true,
                encoding: .utf8
            )
            let probe = DesignLint.scanUI(root: probeRoot, exemptions: [], horizontalInsetWhitelist: [])
            let probeHit = probe.violations.contains { $0.hasPrefix("Views/FakeView.swift") }
            let probeScaleHit = probe.violations.contains {
                $0.hasPrefix("Views/FakeView.swift:4:") && $0.contains("minimumScaleFactor")
            }
            let probeInsetHit = probe.violations.contains {
                $0.hasPrefix("Views/FakeView.swift:5:") && $0.contains("水平内边距")
            }
            let probeFontHit = probe.violations.contains {
                $0.hasPrefix("Views/FakeView.swift:6:") && $0.contains("裸字号")
            }
            check(
                probe.discoveredFiles == ["Views/FakeView.swift"] && probeHit
                    && probeScaleHit && probeInsetHit && probeFontHit,
                "recursion and the three new rules proven by a negative case in a temp subdirectory",
                "discovered=\(probe.discoveredFiles.count) violations=\(probe.violations.count) "
                    + "scale=\(probeScaleHit) inset=\(probeInsetHit) font=\(probeFontHit) "
                    + "first=\(probe.violations.first ?? "-")"
            )
            try? FileManager.default.removeItem(at: probeRoot)
            // 闭合态那一层不允许出现任何文字节点：183pt 的形状正中就是摄像头模组的实体遮挡区，
            // 画在那儿等于画在硬件背后（离屏渲染看不到挖孔，所以图会骗人）。
            let closedTexts = DesignLint.closedLayerTextNodes()
            check(
                closedTexts.isEmpty,
                "closed layer contains no text nodes",
                closedTexts.isEmpty ? "NotchRootView.swift: 0 text" : closedTexts.joined(separator: " | ")
            )

            let axHits = DesignLint.accessibilityAPICalls()
            check(
                axHits.isEmpty,
                "app sources never call the accessibility API",
                axHits.isEmpty ? "0 hit(s) outside main.swift" : axHits.joined(separator: " | ")
            )

            // 10. 播放器兼容开关：第三方默认关闭，系统播放器恒开且不可关闭
            let thirdPartyID = "com.netease.163music"
            UserDefaults.standard.removeObject(forKey: PlayerRegistry.defaultsKey(thirdPartyID))
            check(
                !PlayerRegistry.isEnabled(thirdPartyID) && !PlayerRegistry.allowsReading(thirdPartyID),
                "third-party player is off by default",
                "netease enabled=\(PlayerRegistry.isEnabled(thirdPartyID))"
            )
            PlayerRegistry.setEnabled(true, for: thirdPartyID)
            check(
                PlayerRegistry.isEnabled(thirdPartyID) && PlayerRegistry.allowsReading(thirdPartyID),
                "enabling a third-party player persists",
                "netease enabled=\(PlayerRegistry.isEnabled(thirdPartyID))"
            )
            PlayerRegistry.setEnabled(false, for: thirdPartyID)
            check(
                !PlayerRegistry.isEnabled(thirdPartyID),
                "disabling a third-party player takes effect again",
                "netease enabled=\(PlayerRegistry.isEnabled(thirdPartyID))"
            )
            PlayerRegistry.setEnabled(false, for: "com.apple.Music")
            check(
                PlayerRegistry.isEnabled("com.apple.Music") && PlayerRegistry.isEnabled("com.spotify.client"),
                "system players stay enabled and cannot be switched off",
                "Music=\(PlayerRegistry.isEnabled("com.apple.Music")) Spotify=\(PlayerRegistry.isEnabled("com.spotify.client"))"
            )
            check(
                PlayerRegistry.entries.allSatisfy {
                    !$0.permission.isEmpty && !$0.benefit.isEmpty && !$0.disabledEffect.isEmpty
                },
                "every player states permission, benefit and disabled effect",
                "entries=\(PlayerRegistry.entries.count)"
            )
            // 权限说明必须等于代码实际会发起的请求：逐条比对「条目声明的集合」与
            // 「该通道在 MediaService 里的实现映射」。多写（声明了不会发生的权限）
            // 和少写（真的会发却没声明）都会 FAIL。这条按条目遍历，新增播放器自动纳入。
            let permissionMismatches = PlayerRegistry.entries.filter {
                $0.permissions != MediaService.permissionsRequested(for: $0.channel)
            }
            check(
                permissionMismatches.isEmpty,
                "each player's stated permission equals what the code requests",
                PlayerRegistry.entries.map {
                    "\($0.name): 声明=\($0.permissions.map(\.rawValue).sorted())"
                        + " 实际=\(MediaService.permissionsRequested(for: $0.channel).map(\.rawValue).sorted())"
                }.joined(separator: "；")
            )
            // 反向兜底：声明 Automation 的 App 必须真有 AppleScript 脚本（否则权限永远不会弹），
            // 而有脚本的 App 也必须在设置里列出来（否则用户看不到这个开关）。
            let automationPlayers = Set(PlayerRegistry.entries.filter { $0.permissions.contains(.automation) }.map(\.bundleID))
            check(
                automationPlayers == AppleScriptBackend.supportedBundleIDs,
                "automation players match the AppleScript targets exactly",
                "声明在设置里的=\(automationPlayers.sorted()) 代码里真会调用的=\(AppleScriptBackend.supportedBundleIDs.sorted())"
            )

            // 无屏注入时，把「本环境不覆盖」的项显式打出来：不静默跳过、不假装通过。
            if geometrySource == "injected" {
                print("[SELFTEST] 本环境不覆盖（source=injected，共 \(headlessUncovered.count) 项）：")
                for item in headlessUncovered {
                    print("[SELFTEST] UNCOVERED  \(item)")
                }
            }

            if failures.isEmpty {
                print("[SELFTEST] PASS all \(total) checks  source=\(geometrySource)")
                exit(0)
            } else {
                print("[SELFTEST] FAIL \(failures.count)/\(total) check(s): \(failures.joined(separator: ", "))")
                exit(1)
            }
        }
    }

    private func onScreenWindowInfo(pid: pid_t) -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    }

    /// 通过 CGWindowList 确认窗口真的被 WindowServer 合成在屏幕上。
    private func onScreenWindowBounds(pid: pid_t) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }

        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            return bounds
        }
    }

    // MARK: - 动画采样：证明开合过程中确实存在中间帧

    // 整个采样入口只在 DEBUG 构建存在；Release 下 NotchLayoutProbe 等类型根本不参与编译。
    #if DEBUG
    @MainActor
    private func runAnimationProbe() {
        guard let controller else { exit(1) }
        controller.pointerTrackingEnabled = false
        let vm = controller.viewModelForTesting
        let closedHeight = vm.closedSize.height
        let openHeight = PageMetrics.shapeSize(for: .home).height

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)

            func intervals(_ times: [TimeInterval]) -> (min: Double, avg: Double, max: Double) {
                guard times.count > 1 else { return (0, 0, 0) }
                let gaps = (1..<times.count).map { (times[$0] - times[$0 - 1]) * 1000 }
                return (gaps.min()!, gaps.reduce(0, +) / Double(gaps.count), gaps.max()!)
            }

            /// 报告一个阶段：打印尺寸序列、圆角序列、采样间隔，返回中间帧数量与峰值尺寸。
            func report(
                _ label: String,
                sizes: [(time: TimeInterval, size: CGSize)],
                shapes: [(time: TimeInterval, top: CGFloat, bottom: CGFloat)],
                fromHeight: CGFloat,
                toHeight: CGFloat
            ) -> (sizeIntermediate: Int, shapeIntermediate: Int, peak: CGSize) {
                let low = min(fromHeight, toHeight) + 1
                let high = max(fromHeight, toHeight) - 1
                let sizeIntermediate = sizes.filter { $0.size.height > low && $0.size.height < high }.count

                // 圆角从 6/14（闭合）插到 0/24（展开），取顶部圆角判断中间值。
                let firstTop = shapes.first?.top ?? 6
                let lastTop = shapes.last?.top ?? 0
                let topLow = min(firstTop, lastTop) + 0.05
                let topHigh = max(firstTop, lastTop) - 0.05
                let shapeIntermediate = shapes.filter { $0.top > topLow && $0.top < topHigh }.count

                let gaps = intervals(sizes.map { $0.time })
                let peak = sizes.reduce(CGSize.zero) { partial, sample in
                    CGSize(
                        width: max(partial.width, sample.size.width),
                        height: max(partial.height, sample.size.height)
                    )
                }
                print("[ANIM] \(label) sizeSamples=\(sizes.count) intermediate=\(sizeIntermediate)"
                      + " interval min/avg/max=\(String(format: "%.1f", gaps.min))/\(String(format: "%.1f", gaps.avg))/\(String(format: "%.1f", gaps.max))ms")
                print("[ANIM] \(label) sizes=" + sizes.map {
                    String(format: "%.1fx%.1f", $0.size.width, $0.size.height)
                }.joined(separator: ","))
                print("[ANIM] \(label) shapeSamples=\(shapes.count) intermediate=\(shapeIntermediate)"
                      + " radii(top/bottom)=" + shapes.map {
                    String(format: "%.1f/%.1f", $0.top, $0.bottom)
                }.joined(separator: ","))
                print("[ANIM] \(label) peak=\(String(format: "%.1fx%.1f", peak.width, peak.height))")
                return (sizeIntermediate, shapeIntermediate, peak)
            }

            /// 反向阶段的量化：真实转向点前后的速度、平台期、回弹。
            ///
            /// 为什么不在 `vm.close()` 那一行取速度：状态变更要等到下一个 SwiftUI
            /// transaction 才进渲染层，实测滞后 1–2 帧（本次 27ms），那几帧仍是展开动画。
            /// 所以先找「调用之后最高的那一帧」作为真实转向点，再在它两侧取速度。
            ///
            /// 判据（任一成立即视为可复现问题）：
            /// - 平台期：转向后、到达终值前，连续 |Δh| < 0.2pt 累计 ≥ 40ms；
            /// - 回弹：转向后高度再往回长 > 2pt；
            /// - 速度断点：转向后首帧速度 < 转向前的 25%（曲线从 0 重新起动）。
            ///   这一条本轮只报数，不修：它属于「速度继承」那条线。
            func analyzeReverse(
                samples: [(time: TimeInterval, size: CGSize)],
                reversalTime: TimeInterval,
                fromHeight: CGFloat,
                toHeight: CGFloat
            ) -> (hasBreak: Bool, plateauMs: Double, velocityBefore: Double,
                  velocityAfter: Double, jitter: Int, growth: CGFloat, latencyMs: Double) {
                let before = samples.filter { $0.time <= reversalTime }
                let after = samples.filter { $0.time > reversalTime }
                guard before.count >= 2, after.count >= 3 else {
                    print("[ANIM] reverse 采样不足 before=\(before.count) after=\(after.count)")
                    return (false, 0, 0, 0, 0, 0, 0)
                }

                /// 段速度 pt/s（正 = 高度在长）。
                func velocity(_ a: (time: TimeInterval, size: CGSize),
                              _ b: (time: TimeInterval, size: CGSize)) -> Double {
                    let dt = b.time - a.time
                    guard dt > 0 else { return 0 }
                    return Double(b.size.height - a.size.height) / dt
                }

                // 真实转向点：调用之后高度最大的那一帧。
                var peakIndex = 0
                for index in after.indices where after[index].size.height > after[peakIndex].size.height {
                    peakIndex = index
                }
                let turn = after[peakIndex]
                let latencyMs = (turn.time - reversalTime) * 1000

                // 转向前后各取一段（最多 2 帧）的速度。
                let preStart = max(0, peakIndex - 2)
                let velocityBefore = peakIndex > preStart ? velocity(after[preStart], turn) : 0
                let postEnd = min(after.count - 1, peakIndex + 1)
                let velocityAfter = postEnd > peakIndex ? velocity(turn, after[postEnd]) : 0

                // 平台期：只统计「还在往终值走」的阶段（距终值 > 1pt），
                // 否则弹簧尾段本来就有大量 < 0.2pt 的收敛帧，会被误算成停顿。
                var longestRun = 0.0
                var run = 0.0
                var index = peakIndex + 1
                while index < after.count, abs(after[index].size.height - toHeight) > 1 {
                    let dt = (after[index].time - after[index - 1].time) * 1000
                    let dh = abs(after[index].size.height - after[index - 1].size.height)
                    if dh < 0.2 {
                        run += dt
                        longestRun = max(longestRun, run)
                    } else {
                        run = 0
                    }
                    index += 1
                }

                // 回弹/抖动：转向前后是否还出现过更高的帧、以及转向后方向变了几次。
                // 真正看得见的问题是「关到一半又往回长」，不是弹簧尾段的微分噪声。
                let growth = turn.size.height - before.last!.size.height
                var jitter = 0
                var direction = 0
                for item in (peakIndex + 1)..<after.count {
                    let dh = after[item].size.height - after[item - 1].size.height
                    guard abs(dh) >= 0.2 else { continue }
                    let sign = dh > 0 ? 1 : -1
                    if direction != 0, sign != direction { jitter += 1 }
                    direction = sign
                }

                // 转向前后各 6 帧的原始序列：时间相对 `vm.close()`（ms）、高度。
                let windowSamples = before.suffix(6) + after.prefix(12)
                let series = windowSamples.map { sample -> String in
                    String(format: "%.0f:%.1f", (sample.time - reversalTime) * 1000, sample.size.height)
                }.joined(separator: ",")
                let head = Array(after.prefix(12))
                let velocitySeries = head.enumerated().map { item, sample -> String in
                    guard item > 0 else { return "-" }
                    return String(format: "%.0f", velocity(head[item - 1], sample))
                }.joined(separator: ",")
                print("[ANIM] reverse t_ms:h series=\(series)")
                print("[ANIM] reverse vAfter(pt/s)/frame=\(velocitySeries)")

                let speedRatio = abs(velocityBefore) > 1
                    ? abs(velocityAfter / velocityBefore) : 0
                // 速度断点只在「转向前确实在动」时才算（>150pt/s），否则转向点本来就是峰。
                let hasBreak = abs(velocityBefore) > 150 && speedRatio < 0.25
                let hasPlateau = longestRun >= 40
                print(String(
                    format: "[ANIM] reverse turn latency=%.0fms h=%.1f vBefore=%+.0fpt/s vAfter=%+.0fpt/s ratio=%.2f plateau=%.0fms jitter=%d growth=%+.1fpt range=%.0f→%.0f",
                    latencyMs, turn.size.height, velocityBefore, velocityAfter, speedRatio,
                    longestRun, jitter, growth, fromHeight, toHeight
                ))
                let verdict = (hasBreak || hasPlateau || jitter > 0)
                    ? "可复现：断点=\(hasBreak) 平台期=\(hasPlateau) 抖动=\(jitter)"
                    : "无可复现问题"
                print("[ANIM] reverse verdict=\(verdict)")
                return (hasBreak || hasPlateau || jitter > 0, longestRun,
                        velocityBefore, velocityAfter, jitter, growth, latencyMs)
            }

            NotchLayoutProbe.reset()
            NotchLayoutProbe.isEnabled = true

            vm.open()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let openResult = report(
                "open",
                sizes: NotchLayoutProbe.samples,
                shapes: NotchLayoutProbe.shapeSamples,
                fromHeight: closedHeight,
                toHeight: openHeight
            )

            NotchLayoutProbe.reset()
            vm.close()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let closeResult = report(
                "close",
                sizes: NotchLayoutProbe.samples,
                shapes: NotchLayoutProbe.shapeSamples,
                fromHeight: openHeight,
                toHeight: closedHeight
            )

            // 反向：展开 100ms 后立即收起，采整段尺寸序列。
            // 目的只有一个：证明中途反向有没有速度断点或平台期，而不是靠肉眼看。
            // 速度继承是另一条线（本轮不写），这里只量「反向那一刻速度掉到多少」。
            NotchLayoutProbe.reset()
            vm.open()
            try? await Task.sleep(nanoseconds: 100_000_000)
            let reversalTime = ProcessInfo.processInfo.systemUptime
            vm.close()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let reverse = analyzeReverse(
                samples: NotchLayoutProbe.samples,
                reversalTime: reversalTime,
                fromHeight: openHeight,
                toHeight: closedHeight
            )

            NotchLayoutProbe.isEnabled = false
            // 动画全程都必须落在窗口内：宽度超调不能超过窗口宽度，否则中间帧侧边被平切。
            let window = ScreenGeometry.windowSize
            let peak = CGSize(
                width: max(openResult.peak.width, closeResult.peak.width),
                height: max(openResult.peak.height, closeResult.peak.height)
            )
            let contained = peak.width <= window.width && peak.height <= window.height
            print("[ANIM] window=\(String(format: "%.1fx%.1f", window.width, window.height))"
                  + " peak=\(String(format: "%.1fx%.1f", peak.width, peak.height))"
                  + " contained=\(contained)")

            // 判定标准：两个阶段都必须采到 ≥3 个严格位于首尾之间的尺寸，圆角也有中间值，
            // 并且整段动画的峰值尺寸都没超出窗口。
            // 反向断言只卡「可用肉眼看到的问题」：中途平台期与关到一半往回长。
            // 速度断点（曲线从 0 重新起动）属于速度继承那条线，不在本门禁里判红。
            let reverseClean = reverse.plateauMs < 40 && reverse.jitter == 0
            let pass = openResult.sizeIntermediate >= 3 && closeResult.sizeIntermediate >= 3
                && openResult.shapeIntermediate >= 3 && closeResult.shapeIntermediate >= 3
                && contained && reverseClean
            print(pass
                  ? "[ANIM] PASS animation interpolates: open size=\(openResult.sizeIntermediate) shape=\(openResult.shapeIntermediate),"
                    + " close size=\(closeResult.sizeIntermediate) shape=\(closeResult.shapeIntermediate), contained=true"
                  : "[ANIM] FAIL: open size=\(openResult.sizeIntermediate) shape=\(openResult.shapeIntermediate),"
                    + " close size=\(closeResult.sizeIntermediate) shape=\(closeResult.shapeIntermediate), contained=\(contained)")
            // 反向探针只报数据，不改开合判定：这轮先证明有没有问题，再决定修法。
            print(String(
                format: "[ANIM] reverse summary break=%d plateau=%.0fms jitter=%d growth=%+.1fpt latency=%.0fms vBefore=%+.0f vAfter=%+.0f",
                reverse.hasBreak ? 1 : 0, reverse.plateauMs, reverse.jitter,
                reverse.growth, reverse.latencyMs, reverse.velocityBefore, reverse.velocityAfter
            ))
            exit(pass ? 0 : 2)
        }
    }
    #endif

    // MARK: - 离屏渲染：验证形状是否贴住窗口顶边

    /// 离屏渲染用的媒体夹具：不发 Apple Event、不依赖真实播放，
    /// 用来把「拒绝授权 / 未播放 / 播放中」三种界面状态单独拍下来。
    enum MediaFixture: String {
        case none
        case empty
        case playing
        case denied
        /// 只有播放状态（IOPM 通道）：闭合态应当出现播放器图标、且没有任何文字。
        case presence

        /// 夹具对应的首页版式：基线用它挑高度档位，不再靠「所有首页态同高」的假设。
        var homeLayout: HomeLayout {
            switch self {
            case .none, .empty: return .empty
            case .denied: return .permissionDenied
            case .playing: return .playing
            case .presence: return .presenceOnly
            }
        }
    }

    /// 夹具封面：画一张 112×112 的色块（离屏渲染没有真实封面可读）。
    @MainActor
    private func fixtureArtwork() -> Data? {
        let size = NSSize(width: 112, height: 112)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.35, green: 0.32, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedWhite: 1, alpha: 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 28, y: 28, width: 56, height: 56)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

    @MainActor
    private func applyFixture(_ fixture: MediaFixture, to vm: NotchViewModel) {
        switch fixture {
        case .none:
            break
        case .empty:
            vm.applyMedia(.none, permission: .granted)
        case .denied:
            vm.applyMedia(.none, permission: .denied)
        case .playing:
            vm.applyMedia(
                MediaSnapshot(
                    title: "夜空中最亮的星",
                    artist: "逃跑计划",
                    album: "世界",
                    isPlaying: true,
                    artwork: fixtureArtwork(),
                    source: .music
                ),
                permission: .granted
            )
        case .presence:
            vm.applyMedia(
                .presence(bundleID: "com.netease.163music", appName: "网易云音乐", isMusicPlayer: true),
                permission: .denied
            )
        }
    }

    /// 取形如 `--flag=value` 的参数值；没给就返回 nil。
    private func flagValue(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// 打印所有可能用于反推刘海矩形的系统信号，原值输出，不做加工。
    @MainActor
    private func printScreenSignals() {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        print("[SIGNALS] hw.model=\(modelString)")
        let hidden = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["_HIHideMenuBar"] as? Bool
        print("[SIGNALS] _HIHideMenuBar=\(hidden.map(String.init) ?? "nil")")
        print("[SIGNALS] screens.count=\(NSScreen.screens.count) main=\(NSScreen.main?.localizedName ?? "nil")")

        for (index, screen) in NSScreen.screens.enumerated() {
            let insets = screen.safeAreaInsets
            print("[SIGNALS] #\(index) name=\(screen.localizedName)")
            print("[SIGNALS] #\(index) frame=\(screen.frame)")
            print("[SIGNALS] #\(index) visibleFrame=\(screen.visibleFrame)")
            print(String(
                format: "[SIGNALS] #\(index) safeAreaInsets top=%.3f left=%.3f bottom=%.3f right=%.3f",
                insets.top, insets.left, insets.bottom, insets.right
            ))
            print("[SIGNALS] #\(index) auxiliaryTopLeftArea=\(rectText(screen.auxiliaryTopLeftArea))")
            print("[SIGNALS] #\(index) auxiliaryTopRightArea=\(rectText(screen.auxiliaryTopRightArea))")
            print("[SIGNALS] #\(index) backingScaleFactor=\(screen.backingScaleFactor)")
            print("[SIGNALS] #\(index) deviceDescription=\(screen.deviceDescription)")
        }
    }

    private func rectText(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "\(rect)"
    }

    /// 几何探针：把「屏幕宽 − 左右辅助区」当作硬件刘海宽度，按注入参数离屏渲染，
    /// 叠红色禁画区，并打印三项余量。图与数一起看，不依赖物理屏。
    @MainActor
    private func runGeometryProbe(spec: String, outputDirectory: String, label: String) {
        guard let metrics = HeadlessGeometry.metrics(from: spec) else {
            print("[GEOMETRY] FAIL 无法解析几何参数：\(spec)")
            exit(1)
        }
        FileShelfRendering.isOffscreen = true
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 顶部让位与禁画矩形同源：探针也必须走同一个入口，不能自己另算一份。
        PageMetrics.configure(topInset: NotchHardware.topInset(for: metrics))
        NotchHardware.resetCacheCounters()

        let closed = ScreenGeometry.closedSize(for: metrics)
        // 硬件矩形只从 NotchHardware 取，不再用「闭合宽度 − 4」自己反推。
        guard let box = NotchHardware.box(for: metrics) else {
            print("[GEOMETRY] label=\(label) 无刘海（safeAreaTop=0），不设禁画区")
            exit(0)
        }
        let hardware = box.rect.width
        let centerX = ScreenGeometry.windowSize.width / 2
        let scale: CGFloat = 3
        let bandBottom = box.rect.height
        let topInset = PageMetrics.topInset

        // 以下坐标都以窗口水平中心为原点，向右为正。
        let chromeHome = -PageMetrics.shapeSize(for: .home).width / 2 + PageMetrics.contentPadding
        let chromeFiles = -PageMetrics.shapeSize(for: .files).width / 2 + PageMetrics.contentPadding
        let hardwareLeft = -hardware / 2
        let hardwareRight = hardware / 2

        // 徽标位置直接读视图真正用的那个值（`closedBadgeTrailing`），
        // 探针里再写一份公式就会和视图各说各话。
        let badgeVM = NotchViewModel(
            closedSize: closed,
            menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
        )
        applyFixture(.playing, to: badgeVM)
        badgeVM.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: metrics)
        let badgeSlotWidth = badgeVM.notchSize.width
        let badgeLeft = -badgeSlotWidth / 2 + badgeVM.closedBadgeOffset + badgeSlotWidth
            - badgeVM.closedBadgeTrailing - DesignSystem.Size.closedBadge

        print("[GEOMETRY] label=\(label) spec=\(spec)")
        print(String(
            format: "[GEOMETRY] hardware=%.1f estimated=%@ reason=%@ 矩形=%@",
            hardware, box.isEstimated ? "true" : "false", box.reason ?? "nil",
            NSStringFromRect(box.rect)
        ))
        print(String(
            format: "[GEOMETRY] 骨架 顶部=%.0f（硬件 %.0f + gap %.0f） chrome=%.0f 间距=%.0f 底部=%.0f 合计=%.0f",
            topInset, bandBottom, NotchHardware.contentGap,
            PageMetrics.chromeHeight, PageMetrics.rowSpacing,
            PageMetrics.contentPadding,
            topInset + PageMetrics.chromeHeight + PageMetrics.rowSpacing + PageMetrics.contentPadding
        ))
        for shelfCount in [0, 1, 2, 3, 4] {
            let shape = PageMetrics.shapeSize(for: .files, shelfCount: shelfCount)
            let verdict = PageMetrics.contentShareVerdict(for: .files, shelfCount: shelfCount)
            print(String(
                format: "[GEOMETRY] 文件架 %d 条 高=%.0f 内容=%.0f 占比=%.1f%% %@",
                shelfCount, shape.height, verdict.content, verdict.ratio * 100,
                verdict.passes ? "OK" : "BELOW_FLOOR"
            ))
        }
        for item in ExpandedItem.allCases where item != .files {
            let shape = PageMetrics.shapeSize(for: item)
            let verdict = PageMetrics.contentShareVerdict(for: item)
            print(String(
                format: "[GEOMETRY] %@ 高=%.0f 内容=%.0f 占比=%.1f%% %@",
                item.title, shape.height, verdict.content, verdict.ratio * 100,
                verdict.passes ? "OK" : "BELOW_FLOOR"
            ))
        }
        print(String(
            format: "[GEOMETRY] 徽标左缘=%+.1f 硬件右缘=%+.1f 余量=%+.1f %@",
            badgeLeft, hardwareRight, badgeLeft - hardwareRight,
            badgeLeft - hardwareRight >= NotchHardware.contentGap - 0.01 ? "OK" : "INTRUDE"
        ))
        print(String(
            format: "[GEOMETRY] 首页 chrome 左缘=%+.1f 水平余量=%+.1f（竖向让位后不再承担避让）",
            chromeHome, chromeHome - hardwareLeft
        ))
        print(String(
            format: "[GEOMETRY] 文件架 chrome 左缘=%+.1f 水平余量=%+.1f（竖向让位后不再承担避让）",
            chromeFiles, chromeFiles - hardwareLeft
        ))
        print(String(
            format: "[GEOMETRY] chrome 行顶端=%+.1f 硬件底边=%+.1f 垂直余量=%+.1f %@",
            topInset, bandBottom, topInset - bandBottom,
            topInset - bandBottom >= NotchHardware.contentGap - 0.01 ? "OK" : "INTRUDE"
        ))

        let jobs: [(name: String, open: Bool, route: ExpandedItem, fixture: MediaFixture)] = [
            ("closed", false, .home, .none),
            ("closed-playing", false, .home, .playing),
            ("open-home", true, .home, .playing),
            ("open-files", true, .files, .none)
        ]
        var gateFailures = 0
        for job in jobs {
            let vm = NotchViewModel(
                closedSize: closed,
                menuBarHeight: ScreenGeometry.menuBarHeight(for: metrics)
            )
            vm.select(job.route)
            applyFixture(job.fixture, to: vm)
            vm.hardwareHalfWidth = NotchHardware.clearanceHalfWidth(for: metrics)
            if job.open { vm.open() }

            func canvas(withOverlay: Bool, contentOnly: Bool, withShape: Bool) -> some View {
                ZStack(alignment: .topLeading) {
                    // 内容门禁用黑底：黑底与形状同色，禁画区里的亮像素只可能来自内容。
                    if contentOnly {
                        Color.black
                    } else {
                        Color(red: 0.62, green: 0.64, blue: 0.67)
                    }
                    NotchRootView(
                        vm: vm,
                        onTap: {},
                        onSelect: { _ in },
                        onMediaControl: { _ in },
                        onOpenPlayerSettings: {},
                        onDropFiles: { _ in },
                        onDragOutFile: { _, _ in },
                        showsShape: withShape
                    )
                    .frame(width: ScreenGeometry.windowSize.width, height: ScreenGeometry.windowSize.height)
                    .offset(x: 40, y: 40)
                    if withOverlay {
                        // 硬件禁画区：与内容同坐标系，压在面板之上，越界一眼可见。
                        Rectangle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: hardware, height: bandBottom)
                            .offset(x: 40 + centerX - hardware / 2, y: 40)
                    }
                }
                .frame(width: 720, height: 300)
            }

            /// 扫禁画区里亮度 > 0.2 的像素，命中即报列号。
            func scan(_ rep: NSBitmapImageRep, border: Int) -> (hits: Int, columns: [Int]) {
                let px0 = Int(((40 + centerX - hardware / 2) * scale).rounded())
                let py0 = Int((40 * scale).rounded())
                let pw = Int((hardware * scale).rounded())
                let ph = Int((bandBottom * scale).rounded())
                var hits = 0
                var columns: [Int] = []
                for dy in border..<max(border + 1, ph - border) {
                    for dx in border..<max(border + 1, pw - border) {
                        let bx = px0 + dx
                        // NSBitmapImageRep 的 TIFF 数据原点在左上：y 直接向下取，不翻转。
                        let by = py0 + dy
                        guard bx >= 0, bx < rep.pixelsWide, by >= 0, by < rep.pixelsHigh,
                              let color = rep.colorAt(x: bx, y: by) else { continue }
                        let luminance = 0.299 * color.redComponent
                            + 0.587 * color.greenComponent
                            + 0.114 * color.blueComponent
                        if luminance > 0.2 {
                            hits += 1
                            if columns.count < 5 { columns.append(bx) }
                        }
                    }
                }
                return (hits, columns)
            }

            // 唯一门禁：只画内容、不画形状，整块禁画区 0 命中（不设任何豁免）。
            guard let contentRep = renderBitmap(canvas(withOverlay: false, contentOnly: true, withShape: false)) else {
                print("[GEOMETRY] FAIL 渲染失败：\(job.name)")
                exit(1)
            }
            let gate = scan(contentRep, border: 0)
            if gate.hits > 0 { gateFailures += 1 }
            print(String(
                format: "[GEOMETRY] %@ 内容门禁 命中=%d 列号=%@ %@",
                job.name, gate.hits,
                gate.columns.map(String.init).joined(separator: ","),
                gate.hits == 0 ? "OK" : "INTRUDE"
            ))

            // 合成图只做诊断：形状本体的抗锯齿会渗到边界内 2pt，
            // 差异只允许按这一圈解释（豁免仅这 2pt，不扩到整块禁画区）。
            guard let compositeRep = renderBitmap(canvas(withOverlay: false, contentOnly: false, withShape: true)) else {
                print("[GEOMETRY] FAIL 渲染失败：\(job.name)")
                exit(1)
            }
            let border = Int((
                NotchHardware.antialiasOverhang(closedWidth: closed.width, hardwareWidth: hardware) * scale
            ).rounded())
            let diagnostic = scan(compositeRep, border: border)
            print(String(
                format: "[GEOMETRY] %@ 合成图诊断 豁免 %dpx 后命中=%d 列号=%@",
                job.name, border, diagnostic.hits,
                diagnostic.columns.map(String.init).joined(separator: ",")
            ))

            // 交付图不画形状裁剪：离屏渲染里 `clipShape` 会留下固定的亮边与角部占位色，
            // 那是 ImageRenderer 的假象、不是屏幕上的样子。形状宽度不变，遮挡判断不受影响。
            guard let overlayRep = renderBitmap(canvas(withOverlay: true, contentOnly: false, withShape: false)),
                  let png = overlayRep.representation(using: .png, properties: [:]) else {
                print("[GEOMETRY] FAIL 渲染失败：\(job.name)")
                exit(1)
            }
            let url = dir.appendingPathComponent("\(label)-\(job.name).png")
            try? png.write(to: url)
            print("[GEOMETRY] wrote \(url.path)")
        }

        // 反向用例：把一块白色方块硬塞进禁画区正中，断言必须变红并报出列号。
        let negativeCanvas = ZStack(alignment: .topLeading) {
            Color(red: 0.62, green: 0.64, blue: 0.67)
            Rectangle()
                .fill(Color.white)
                .frame(width: 40, height: 20)
                .offset(x: 40 + centerX - 20, y: 40 + metrics.safeAreaTop / 2 - 10)
        }
        .frame(width: 720, height: 300)
        if let negative = renderBitmap(negativeCanvas) {
            let px0 = Int(((40 + centerX - hardware / 2) * scale).rounded())
            let py0 = Int((40 * scale).rounded())
            let pw = Int((hardware * scale).rounded())
            let ph = Int((metrics.safeAreaTop * scale).rounded())
            var negHits = 0
            var negColumns: [Int] = []
            for dy in 0..<ph {
                for dx in 0..<pw {
                    let bx = px0 + dx
                    let by = py0 + dy
                    guard bx >= 0, bx < negative.pixelsWide, by >= 0, by < negative.pixelsHigh,
                          let color = negative.colorAt(x: bx, y: by) else { continue }
                    let luminance = 0.299 * color.redComponent
                        + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                    if luminance > 0.2 {
                        negHits += 1
                        if negColumns.count < 5 { negColumns.append(bx) }
                    }
                }
            }
            print(String(
                format: "[GEOMETRY] 反向用例 命中=%d 列号=%@ %@",
                negHits, negColumns.map(String.init).joined(separator: ","),
                negHits > 0 && !negColumns.isEmpty ? "NEGATIVE_OK" : "NEGATIVE_FAIL"
            ))
            if negHits == 0 || negColumns.isEmpty { gateFailures += 1 }
        }

        // 缓存自检：同一配置第二次调用不再计算，配置一变必重算。
        let before = NotchHardware.computeCount
        _ = NotchHardware.box(for: metrics)
        let afterHit = NotchHardware.computeCount
        var changed = metrics
        changed.safeAreaTop += 1
        _ = NotchHardware.box(for: changed)
        let afterChange = NotchHardware.computeCount
        let cacheOK = afterHit == before && afterChange == before + 1
        if !cacheOK { gateFailures += 1 }
        print(
            "[GEOMETRY] 缓存 首次后=\(before) 第二次=\(afterHit) 改配置后=\(afterChange) "
                + (cacheOK ? "CACHE_OK" : "CACHE_FAIL")
        )

        if gateFailures == 0 {
            print("[GEOMETRY] PASS 内容门禁 0 命中（@\(Int(scale))x）")
            exit(0)
        }
        print("[GEOMETRY] FAIL 内容门禁/反向用例/缓存 共 \(gateFailures) 项")
        exit(2)
    }

    @MainActor
    private func renderBitmap(_ view: some View) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// 渲染一张离屏快照（画布 720×300pt，@2x → 1440×600 设备像素，窗口原点固定在 (40,40)pt）。
    ///
    /// `withMarker = false` 时**不画**红色标注线：红线横跨整个窗口宽度、
    /// 覆盖 y∈[0,1)pt，会把侧边与顶边的采样一并压暗，不能用来量阴影。
    @MainActor
    private func renderCanvas(
        open: Bool,
        route: ExpandedItem = .home,
        fixture: MediaFixture = .none,
        shelfCount: Int = 0,
        screen: NSScreen,
        withMarker: Bool,
        scale: CGFloat = 2,
        showsShape: Bool = true,
        canvasBackground: Color? = nil
    ) -> NSBitmapImageRep? {
        let vm = NotchViewModel(
            closedSize: ScreenGeometry.closedSize(for: screen),
            menuBarHeight: ScreenGeometry.menuBarHeight(for: screen)
        )
        vm.select(route)
        applyFixture(fixture, to: vm)
        // 文件架的四个非空状态需要真实条目：用临时文件换取真实图标与大小。
        let shelfFiles = makeShelfFixtureFiles(count: shelfCount)
        if !shelfFiles.isEmpty { vm.addShelfFiles(shelfFiles) }
        if open { vm.open() }

        // 背景模拟菜单栏；红色 1px 线标记窗口顶边（y = 40）。
        let canvas = ZStack(alignment: .topLeading) {
            canvasBackground ?? Color(red: 0.62, green: 0.64, blue: 0.67)
            NotchRootView(
                vm: vm,
                onTap: {},
                onSelect: { _ in },
                onMediaControl: { _ in },
                onOpenPlayerSettings: {},
                onDropFiles: { _ in },
                onDragOutFile: { _, _ in },
                showsShape: showsShape
            )
            .frame(width: ScreenGeometry.windowSize.width, height: ScreenGeometry.windowSize.height)
            .offset(x: 40, y: 40)
            if withMarker {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: ScreenGeometry.windowSize.width, height: 1)
                    .offset(x: 40, y: 40)
            }
        }
        .frame(width: 720, height: 300)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// 文件架渲染用的真实文件：临时目录里按固定大小预置，换取真实图标与大小文本。
    /// 只创建引用，渲染结束后不去动用户的任何文件。
    @MainActor
    private func makeShelfFixtureFiles(count: Int) -> [URL] {
        guard count > 0 else { return [] }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notch-render-shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(name: String, bytes: Int64)] = [
            ("设计稿-final.pdf", 1_400_000),
            ("IMG_2043.HEIC", 2_300_000),
            ("录音.m4a", 860_000),
            ("素材包.zip", 24_000_000),
            ("笔记.md", 4_200)
        ]
        return specs.prefix(count).map { name, bytes in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.truncate(atOffset: UInt64(bytes))
                    try? handle.close()
                }
            }
            return url
        }
    }

    @MainActor
    private func renderSnapshots(to directory: String, screen: NSScreen) {
        // `ImageRenderer` 画不了 `ScrollView`：文件架改用同尺寸裁剪容器。
        FileShelfRendering.isOffscreen = true
        // 设置页列表图标用同一个确定性夹具，保证离屏快照也跨机器可复现。
        PlayerIconFixture.symbolName = PlayerIconFixture.baselineSymbol
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 闭合态两张（无播放 / 播放中缩略图）+ 展开态每页一张 + 首页三种媒体状态。
        var jobs: [(name: String, open: Bool, route: ExpandedItem, fixture: MediaFixture, shelf: Int)] = [
            ("closed.png", false, .home, .none, 0),
            ("closed-playing.png", false, .home, .playing, 0),
            ("closed-presence.png", false, .home, .presence, 0)
        ]
        for item in ExpandedItem.allCases {
            jobs.append(("open-\(item.rawValue).png", true, item, item == .home ? .playing : .none, 0))
        }
        // 文件架五个状态各一张：空架（上面的 open-files.png）+ 1/2/3/4 条。
        for count in 1...4 {
            jobs.append(("open-files-\(count).png", true, .files, .none, count))
        }
        jobs.append(("open-home-denied.png", true, .home, .denied, 0))
        jobs.append(("open-home-empty.png", true, .home, .empty, 0))
        jobs.append(("open-home-presence.png", true, .home, .presence, 0))
        // 兼容旧命名：open.png = 首页。
        jobs.append(("open.png", true, .home, .playing, 0))

        let enabledPlayers = PlayerRegistry.entries
            .filter(\.isThirdParty)
            .filter { PlayerRegistry.isEnabled($0.bundleID) }
            .count

        for job in jobs {
            NSLog("[RENDER] rendering %@", job.name)
            guard let rep = renderCanvas(
                open: job.open,
                route: job.route,
                fixture: job.fixture,
                shelfCount: job.shelf,
                screen: screen,
                withMarker: true
            ),
                  let png = rep.representation(using: .png, properties: [:]) else {
                print("[RENDER] failed at \(job.name)")
                continue
            }
            // 闭合态有播放会话时形状向右加宽一个缩略图位（20 + 8），这里照实报宽度。
            let hasBadge = job.fixture == .playing || job.fixture == .presence
            let closedWidth = ScreenGeometry.closedSize(for: screen).width
                + (hasBadge ? DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm : 0)
            let size = job.open
                ? PageMetrics.shapeSize(
                    for: job.route,
                    shelfCount: job.shelf,
                    home: job.fixture.homeLayout,
                    playersEnabled: job.route == .players ? enabledPlayers : 0
                  )
                : CGSize(width: closedWidth, height: ScreenGeometry.closedSize(for: screen).height)
            let url = dir.appendingPathComponent(job.name)
            let renderedContentHeight = PageMetrics.contentHeight(
                for: job.route,
                shelfCount: job.shelf,
                home: job.fixture.homeLayout,
                playersEnabled: job.route == .players ? enabledPlayers : 0
            )
            do {
                try png.write(to: url)
                let detail = job.open
                    ? " content=\(Int(job.route.contentSize.width))x\(Int(renderedContentHeight))"
                        + " padding=\(Int(PageMetrics.contentPadding))"
                    : ""
                print("[RENDER] wrote \(job.name) shape=\(Int(size.width))x\(Int(size.height))\(detail)")
            } catch {
                print("[RENDER] write failed: \(error)")
            }
        }

        // 播放器兼容设置窗口（独立窗口，不在刘海面板里）：单独渲染一张，方便核对三行说明有没有被裁。
        let settingsVM = NotchViewModel(
            closedSize: ScreenGeometry.closedSize(for: screen),
            menuBarHeight: ScreenGeometry.menuBarHeight(for: screen)
        )
        let settingsContent = PlayerSettingsView(vm: settingsVM, onTogglePlayer: { _, _ in })
            .frame(width: DesignSystem.Size.settingsWidth)
        let settingsRenderer = ImageRenderer(content: settingsContent)
        settingsRenderer.scale = 2
        settingsRenderer.proposedSize = ProposedViewSize(
            width: DesignSystem.Size.settingsWidth,
            height: 700
        )
        if let image = settingsRenderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("settings-players.png"))
            print("[RENDER] wrote settings-players.png shape=\(Int(image.size.width))x\(Int(image.size.height))")
        }
        exit(0)
    }

    /// `--media-probe`：对真实播放器跑一遍 AppleScript 主路径。
    ///
    /// 需要本机在 Music / Spotify 里放一首歌，并在系统弹窗里允许 Automation。
    /// 只做一次 playpause 往返（再切回原状态），验证「读到的」和「控制真的生效」。
    @MainActor
    private func runMediaProbe() {
        var lines: [String] = []
        let outputPath: String? = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }()
        func log(_ line: String) {
            lines.append(line)
            print(line)
        }
        // `exit` 不跑 defer，所以落盘放在这里，每条退出路径都经过它。
        func finish(_ code: Int32) -> Never {
            if let outputPath {
                try? lines.joined(separator: "\n").write(
                    toFile: outputPath, atomically: true, encoding: .utf8
                )
            }
            exit(code)
        }

        let backend = AppleScriptBackend()
        log("[MEDIA] backend=\(backend.name)（媒体通道选型见 README「媒体通道实测结论」）")

        do {
            let before = try backend.readSnapshot()
            if !before.hasTrack {
                log("[MEDIA] no track: 播放器未运行或已停止（source=\(before.source.rawValue)）")
                finish(0)
            }
            let artworkBytes = (try? backend.readArtwork())?.count ?? 0
            log("[MEDIA] track title=\(before.title) artist=\(before.artist) album=\(before.album)")
            log("[MEDIA] state=\(before.isPlaying ? "playing" : "paused") artworkBytes=\(artworkBytes)")

            // 控制往返：切一次再切回来，确保不改变用户原状态。
            try backend.perform(.playPause)
            Thread.sleep(forTimeInterval: 1.2)
            let toggled = try backend.readSnapshot()
            log("[MEDIA] after playpause state=\(toggled.isPlaying ? "playing" : "paused")"
                + " title=\(toggled.title)")

            try backend.perform(.playPause)
            Thread.sleep(forTimeInterval: 1.0)
            let restored = try backend.readSnapshot()
            log("[MEDIA] restored state=\(restored.isPlaying ? "playing" : "paused")")

            let flipped = toggled.isPlaying != before.isPlaying
            let back = restored.isPlaying == before.isPlaying
            log(flipped && back
                ? "[MEDIA] PASS control round-trip (state flipped then restored)"
                : "[MEDIA] FAIL control round-trip (flipped=\(flipped) restored=\(back))")
            finish(flipped && back ? 0 : 2)
        } catch MediaError.notAuthorized {
            log("[MEDIA] DENIED: Automation 授权被拒绝（-1743）。界面会显示授权引导行。")
            finish(3)
        } catch {
            log("[MEDIA] ERROR: \(error.localizedDescription)")
            finish(2)
        }
    }

    // MARK: - 功耗探针：同进程 A/B

    /// 探针里可切换的 presence 源：同一个 `MediaService` 实例在 ON/OFF 两臂之间复用，
    /// 只有「是否注入播放中的断言」不同，其他组件（CoreAudio 监听、AppleScript 通道）完全一致。
    private final class PresenceSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AudioPresence?

        func set(_ presence: AudioPresence?) {
            lock.lock()
            value = presence
            lock.unlock()
        }

        func current() -> AudioPresence? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// 功耗探针专用的空后端：AppleScript 会把播放器拉起来、也可能弹授权框，
    /// 混进采样就分不清唤醒是复核表还是脚本通道产生的。
    private struct NoopBackend: MediaBackend {
        let name = "noop"
        func readSnapshot() throws -> MediaSnapshot { .none }
        func readArtwork() throws -> Data? { nil }
        func perform(_ control: MediaControl) throws {}
    }

    /// 一次采样点。两条仪器同时读：
    /// - `task_info(TASK_POWER_INFO_V2)`：进程自己的 `task_interrupt_wakeups` 与 `task_energy`（nJ）；
    /// - `proc_pid_rusage(RUSAGE_INFO_V4)`：`ri_interrupt_wkups` / `ri_pkg_idle_wkups`，交叉验证。
    private struct PowerSample {
        var taskInterrupt: UInt64 = 0
        var taskTimer: UInt64 = 0
        var energyNJ: UInt64 = 0
        var rusageInterrupt: UInt64 = 0
        var rusageIdle: UInt64 = 0
        var cpu: Double = 0

        static func read() -> PowerSample {
            var sample = PowerSample()

            var info = task_power_info_v2_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<integer_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), rebound, &count)
                }
            }
            if kr == KERN_SUCCESS {
                sample.taskInterrupt = info.cpu_energy.task_interrupt_wakeups
                sample.taskTimer = info.cpu_energy.task_timer_wakeups_bin_1 + info.cpu_energy.task_timer_wakeups_bin_2
                sample.energyNJ = info.task_energy
            }

            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
                }
            }
            if status == 0 {
                sample.rusageInterrupt = usage.ri_interrupt_wkups
                sample.rusageIdle = usage.ri_pkg_idle_wkups
                sample.cpu = Double(usage.ri_user_time + usage.ri_system_time) / 1_000_000_000
            }
            return sample
        }

        func delta(from before: PowerSample) -> PowerSample {
            PowerSample(
                taskInterrupt: taskInterrupt &- before.taskInterrupt,
                taskTimer: taskTimer &- before.taskTimer,
                energyNJ: energyNJ &- before.energyNJ,
                rusageInterrupt: rusageInterrupt &- before.rusageInterrupt,
                rusageIdle: rusageIdle &- before.rusageIdle,
                cpu: cpu - before.cpu
            )
        }
    }

    /// `--power-probe`：同一进程内做「复核表开 / 关」的 A/B，回答 2s 复核表到底有没有产生唤醒。
    ///
    /// 之前的问题：三段窗口（idle-1 / playing / idle-2）`interruptWkups` 全是 6，
    /// 而 playing 段明明触发了 4 次复核。要么计数器看不见这类唤醒，要么 6 来自固定周期源——
    /// 当时用「复用 RunLoop 唤醒时间片」解释属于推测，这里改成能直接证伪的对照实验：
    ///
    /// 1. 仪器校准：本进程挂 0.4s 定时器 10s，应看到约 25 次中断唤醒；看不到就说明仪器不灵。
    /// 2. 同一个 `MediaService`（同一进程、同一 CoreAudio 监听、同一个空后端），
    ///    交替 ON / OFF 各 20s：ON 注入播放中的断言让 2s 复核表挂上，OFF 让表停掉。
    /// 3. 每段记录复核触发次数与两条仪器的唤醒增量，差异必须和触发次数对得上。
    @MainActor
    private func runPowerProbe() {
        controller?.stopMediaForTesting()

        let window: TimeInterval = 20
        print("[POWER] pid=\(getpid())  仪器 task_info(TASK_POWER_INFO_V2).task_interrupt_wakeups / task_energy"
              + " + proc_pid_rusage(RUSAGE_INFO_V4) 交叉验证")

        /// 采样窗口只调用一次 `run(until:)`：分片轮询会让主线程每 0.5s 醒一次，
        /// 那本身就是唤醒源，会把被测组件的差异淹掉（上一版 48/20s 的底噪就是分片造成的）。
        func measure(_ seconds: TimeInterval) -> PowerSample {
            let before = PowerSample.read()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            return PowerSample.read().delta(from: before)
        }

        // 1. 仪器校准与底噪：先空跑 10s 看这台机器上「什么都不做」的底噪，
        //    再挂 0.4s 定时器 10s，确认定时器唤醒能被数出来。
        print("[POWER] 底噪：空跑 10s（无定时器、无 MediaService）")
        let baseline = measure(10)
        print(
            String(format: "[POWER] 底噪结果  taskInterrupt=+%d  rusageInterrupt=+%d  idle=+%d  energy=+%.2fmJ",
                   baseline.taskInterrupt, baseline.rusageInterrupt,
                   baseline.rusageIdle, Double(baseline.energyNJ) / 1_000_000)
        )
        print("[POWER] 仪器校准：0.4s 定时器跑 10s（理论 ~25 次触发）")
        let calibrationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in }
        let calibration = measure(10)
        calibrationTimer.invalidate()
        print(
            String(
                format: "[POWER] 校准结果  taskInterrupt=+%d  rusageInterrupt=+%d  taskTimerBin=+%d  energy=+%.2fmJ",
                calibration.taskInterrupt, calibration.rusageInterrupt,
                calibration.taskTimer, Double(calibration.energyNJ) / 1_000_000
            )
        )

        // 2. 静置：启动、窗口首次合成、字体/图标解码都在这段时间里发生。
        print("[POWER] 启动后静置 10s 再采样 ...")
        RunLoop.main.run(until: Date().addingTimeInterval(10))

        // 3. 同进程 A/B：一个 service 实例，交替 ON / OFF
        let box = PresenceSwitch()
        let service = MediaService(backend: NoopBackend(), presence: { box.current() })
        service.onChange = { _, _ in }
        service.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        // 用系统里真实存在的音乐 App 的 bundle id，让分类器走真实路径（不是伪造字符串）。
        let fake = AudioPresence(
            pid: getpid(), bundleID: "com.apple.Music", appName: "Music",
            isPlaying: true, assertionID: 1
        )

        func arm(_ label: String, playing: Bool) -> (fires: Int, sample: PowerSample) {
            box.set(playing ? fake : nil)
            service.refreshPresence()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let beforeFires = service.presenceVerifyFires
            let sample = measure(window)
            let fires = service.presenceVerifyFires - beforeFires
            print(
                String(
                    format: "[POWER] %@ %.0fs  verifyFires=%2d  中断唤醒=+%d  空闲唤醒=+%d  能耗=+%.2fmJ  CPU=+%.3fs"
                        + "  (rusage interrupt=+%d idle=+%d)",
                    label, window, fires,
                    sample.taskInterrupt, sample.rusageIdle,
                    Double(sample.energyNJ) / 1_000_000,
                    sample.cpu,
                    sample.rusageInterrupt, sample.rusageIdle
                )
            )
            return (fires, sample)
        }

        let on1 = arm("A1 复核表 ON ", playing: true)
        let off1 = arm("B1 复核表 OFF", playing: false)
        let on2 = arm("A2 复核表 ON ", playing: true)
        let off2 = arm("B2 复核表 OFF", playing: false)
        service.stop()

        // 4. 结论只看数字：差值与触发次数对不对得上。
        let onWake = Double(on1.sample.taskInterrupt + on2.sample.taskInterrupt) / 2
        let offWake = Double(off1.sample.taskInterrupt + off2.sample.taskInterrupt) / 2
        let onFires = Double(on1.fires + on2.fires) / 2
        let diff = onWake - offWake
        print(String(format: "[POWER] 汇总：ON 平均中断唤醒 %.1f/%.0fs（复核平均 %.1f 次），OFF 平均 %.1f/%.0fs，差 %.1f",
                     onWake, window, onFires, offWake, window, diff))
        if abs(diff - onFires) <= 1.5 {
            print("[POWER] 结论：复核表每触发一次就多一次中断唤醒，差值 ≈ 触发次数，代价可量化。")
        } else if diff >= 1.0 && diff <= onFires + 1.5 {
            // 定时器允许合并（tolerance 0.5s），所以唤醒数 ≤ 触发数才是正常形态；
            // 只要差值明显大于底噪、又不超过触发次数，就能把这段开销归给复核表。
            print("[POWER] 结论：复核表确实带来额外唤醒（差值 \(String(format: "%.1f", diff)) ≤ 触发数 \(String(format: "%.1f", onFires))），"
                  + "每次触发最多一次唤醒；差额是定时器合并，不是未归因来源。")
        } else if abs(diff) < 1.0 {
            print("[POWER] 结论：测不准——这台机器上仪器看不到复核表带来的差异，README 里按「测不准」写，不编解释。")
        } else {
            print("[POWER] 结论：唤醒数超过触发次数，存在未归因的唤醒源，需要继续查。")
        }
        exit(0)
    }

    // MARK: - 播放状态探针：IOPM 零权限通道

    /// `--presence-probe`：实测 IOPM 通道，并用合成断言补齐「暂停 / App 未运行」两种降级。
    ///
    /// 只读断言字典，不发送任何播放控制指令。
    @MainActor
    private func runPresenceProbe() {
        guard let vm = controller?.viewModelForTesting else {
            print("[PRESENCE] FAIL: controller not created")
            exit(1)
        }
        var failures = 0
        var total = 0
        func check(_ ok: Bool, _ name: String, _ detail: String) {
            total += 1
            print("[PRESENCE] \(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !ok { failures += 1 }
        }
        func makeVM() -> NotchViewModel {
            NotchViewModel(closedSize: vm.closedSize, menuBarHeight: vm.menuBarHeight)
        }

        // 1. 实机：当前谁在播
        let live = AudioPresenceReader.current()
        if let live {
            print("[PRESENCE] live pid=\(live.pid) bundle=\(live.bundleID) app=\(live.appName) playing=\(live.isPlaying)")
            check(
                live.bundleID == "com.netease.163music" && live.isPlaying,
                "live IOPM assertion reports netease playing",
                "bundle=\(live.bundleID) playing=\(live.isPlaying)"
            )
        } else {
            print("[PRESENCE] live = nil（此刻没有任何 App 在输出音频，下面的合成用例仍会跑）")
        }

        // 2. 解析器：合成断言（暂停与 App 未运行都靠这里覆盖）
        let neteasePID: pid_t = 90938
        let raw: [NSNumber: [[String: Any]]] = [
            NSNumber(value: neteasePID): [[
                "AssertName": "网易云音乐 is playing music",
                "AssertType": "PreventUserIdleSystemSleep",
                "AssertPID": NSNumber(value: neteasePID),
                "AssertionId": NSNumber(value: 4211),
            ]]
        ]
        let resolver: (pid_t) -> (bundleID: String, appName: String)? = { pid in
            pid == neteasePID ? ("com.netease.163music", "网易云音乐") : nil
        }
        let parsed = AudioPresenceReader.presences(from: raw, resolve: resolver)
        check(
            parsed.count == 1 && parsed.first?.bundleID == "com.netease.163music" && parsed.first?.isPlaying == true,
            "parser maps one IOPM assertion to one playing app",
            parsed.map { "\($0.bundleID) playing=\($0.isPlaying)" }.joined(separator: ",")
        )
        let paused = AudioPresenceReader.presences(from: [:], resolve: resolver)
        check(paused.isEmpty, "paused player yields no presence", "count=\(paused.count)")
        let dead = AudioPresenceReader.presences(from: raw) { _ in nil }
        check(dead.isEmpty, "assertion of a quit app is dropped", "count=\(dead.count)")

        // 3. 界面推导：状态 / 曲目 / 空 三种快照
        let presenceVM = makeVM()
        let closedWidth = presenceVM.notchSize.width
        presenceVM.applyMedia(
            .presence(bundleID: "com.netease.163music", appName: "网易云音乐", isMusicPlayer: true),
            permission: .denied
        )
        let presenceExtra = presenceVM.notchSize.width - closedWidth
        check(
            presenceVM.showsClosedBadge
                && presenceExtra == DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm
                && presenceVM.closedBadgeOffset == presenceExtra / 2,
            "presence-only fills the right badge slot with the app icon",
            "width=\(Int(presenceVM.notchSize.width))"
                + " offset=\(presenceVM.closedBadgeOffset) icon=\(AppIconCache.icon(forBundleID: presenceVM.media.bundleID) != nil)"
        )
        // 音乐类过滤：IOPM 会命中网页视频 / 语音 / 游戏，这些不该点亮闭合态。
        let musicCases: [(bundleID: String, expected: Bool)] = [
            ("com.netease.163music", true),
            ("com.apple.Music", true),
            ("com.google.Chrome", false),
            ("com.apple.Safari", false),
            ("com.tencent.xinWeChat", false)
        ]
        let musicDetail = musicCases
            .map { "\($0.bundleID)=\(MusicAppClassifier.isMusicPlayer(bundleID: $0.bundleID))" }
            .joined(separator: " ")
        check(
            musicCases.allSatisfy { MusicAppClassifier.isMusicPlayer(bundleID: $0.bundleID) == $0.expected },
            "music filter keeps browsers and chat out",
            musicDetail
        )
        let browserVM = makeVM()
        let browserWidth = browserVM.notchSize.width
        browserVM.applyMedia(
            .presence(bundleID: "com.apple.Safari", appName: "Safari", isMusicPlayer: false),
            permission: .granted
        )
        check(
            !browserVM.showsClosedBadge && browserVM.notchSize.width == browserWidth,
            "non-music audio process does not light the closed notch",
            "bundle=com.apple.Safari badge=\(browserVM.showsClosedBadge) width=\(Int(browserVM.notchSize.width))"
        )
        // 白名单优先于自报类别：国内播放器常自报 entertainment / utilities，
        // 按类别硬筛会把核过的 App 误伤掉。这里打印真实读到的值，不假设。
        print("[PRESENCE] 白名单 App 自报的 LSApplicationCategoryType（运行时读 Info.plist）：")
        let reports = MusicAppClassifier.whitelist.map { MusicAppClassifier.categoryReport(bundleID: $0) }
        for report in reports {
            print("[PRESENCE]   \(report.bundleID)  category=\(report.declaredCategory ?? "<未读到>")"
                  + "  whitelist=\(report.whitelisted)  accept=\(report.accepted)"
                  + "  path=\(report.appPath ?? "<未安装/未运行>")")
        }
        let sampleReports = ["com.google.Chrome", "com.apple.Safari", "com.tencent.xinWeChat"]
            .map { MusicAppClassifier.categoryReport(bundleID: $0) }
        for report in sampleReports {
            print("[PRESENCE]   非白名单样本 \(report.bundleID)  category=\(report.declaredCategory ?? "<未读到>")"
                  + "  accept=\(report.accepted)  path=\(report.appPath ?? "<未安装/未运行>")")
        }
        check(
            reports.allSatisfy(\.accepted) && sampleReports.allSatisfy { !$0.accepted },
            "whitelist wins over declared category",
            "whitelist accepted=\(reports.filter(\.accepted).count)/\(reports.count)"
                + " nonMusic=\(sampleReports.map { "\($0.bundleID):\($0.declaredCategory ?? "-")" }.joined(separator: ","))"
        )
        // 规则本身也单独断言：白名单里自报 entertainment 的播放器仍然放行，
        // 白名单外自报 music 的（例如新播放器）也放行，其余拒绝。
        check(
            MusicAppClassifier.accepts(bundleID: "com.tencent.QQMusic", category: "public.app-category.entertainment")
                && MusicAppClassifier.accepts(bundleID: "com.kugou.mac", category: "public.app-category.utilities")
                && MusicAppClassifier.accepts(bundleID: "com.example.newplayer", category: nil) == false
                && MusicAppClassifier.accepts(bundleID: "com.example.newplayer", category: "public.app-category.music")
                && MusicAppClassifier.accepts(bundleID: "com.google.Chrome", category: "public.app-category.productivity") == false,
            "whitelist hit bypasses a misleading declared category",
            "QQMusic@entertainment=true KuGou@utilities=true new@music=true new@nil=false Chrome@productivity=false"
        )
        // 闭合层不许出现文字：183pt 的中心是摄像头模组的实体遮挡区。
        let closedTexts = DesignLint.closedLayerTextNodes()
        check(closedTexts.isEmpty, "closed layer contains no text nodes", "NotchRootView.swift text=" + "\(closedTexts.count)")
        let trackVM = makeVM()
        trackVM.applyMedia(
            MediaSnapshot(title: "晴天", artist: "周杰伦", album: "叶惠美",
                          isPlaying: true, artwork: nil, source: .spotify),
            permission: .granted
        )
        check(
            trackVM.media.hasTrack && trackVM.showsClosedBadge
                && trackVM.notchSize.width == closedWidth + DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm,
            "track from AppleScript keeps the badge path",
            "title=\(trackVM.media.title) width=\(Int(trackVM.notchSize.width))"
        )
        let emptyVM = makeVM()
        emptyVM.applyMedia(.none, permission: .granted)
        check(
            !emptyVM.showsClosedBadge,
            "no session hides everything",
            "width=\(Int(emptyVM.notchSize.width))"
        )

        // 4. CoreAudio 事件源：监听真的挂上了才算数
        let monitor = AudioProcessMonitor()
        monitor.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let processes = AudioProcessMonitor.processObjects().count
        check(
            monitor.isRunning && monitor.monitoredObjectCount > 0 && monitor.monitoredObjectCount == processes,
            "coreaudio monitor attaches to every audio process object",
            "objects=\(processes) monitored=\(monitor.monitoredObjectCount)"
        )
        monitor.stop()
        check(!monitor.isRunning && monitor.monitoredObjectCount == 0, "coreaudio monitor detaches cleanly", "monitored=0")

        print(failures == 0 ? "[PRESENCE] PASS all \(total) checks" : "[PRESENCE] FAIL \(failures)/\(total)")
        exit(failures == 0 ? 0 : 2)
    }

    // MARK: - 视觉基线（--render-baseline）

    /// 每条断言的**期望值来源**。来源写不出来的断言不允许存在，也不允许写「当前实现如此」。
    /// - `aux`：`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 推出的硬件带宽（本机 179）
    /// - `safeTop`：`safeAreaInsets.top`（本机 32）
    /// - `design`：设计常量 + 其外部依据（见 ScreenGeometry / PageMetrics 注释）
    private enum AssertionSources {
        static let map: [String: String] = [
            "state-open": "vm.isOpen（状态事实，不需要渲染期望）",
            "shape-position": "aux 反推闭合宽 179+4；肩部内缩量 = 当前状态的切点偏移 t（闭合 6 / 展开 19，来源=参照实现）",
            "inside-center": "形状内本应不透明黑（design 面板底色）",
            "outside-left": "闭合 a=0：design 阴影不透明度 0；展开 a<250：design 阴影 0.35/radius 4",
            "outside-right": "同 outside-left",
            "outside-bottom": "同 outside-left",
            "corner-left": "耳部在禁画带内，透背景才对；t 取当前状态（闭合 6 / 展开 19，来源=参照实现）",
            "corner-right": "同 corner-left",
            "solid-left": "设计常量：肩部内侧 t+2 必须落在实体上（t 取当前状态）",
            "solid-right": "同 solid-left（带徽标时按本体宽度定位）",
            "shoulder-boundary": "二次曲线解析解 0.914t；t 取当前状态（闭合 6 / 展开 19，来源=参照实现，绝对值未实测）",
            "shoulder-arc": "design 抗锯齿过渡带宽度 1...4px（同色 overscan 只遮 1px）",
            "shoulder-family": "解析内收 t(2√(y/t)−y/t)，容差 0.75pt；两态共用同一条构造，t 按状态取 6/19（同族=构造相同，不是数值相同）",
            "edge-left": "windowFrame 量化到整设备像素（backingScaleFactor）+ 同色 overscan 1px",
            "edge-right": "同 edge-left",
            "edge-bottom": "同 edge-left；展开态阈值 8px 含阴影过渡",
            "content-not-clipped": "PageMetrics.heightBudget：内容 + chrome + 自有留白 + 系统让位（safeTop−16）",
            "content-overflow": "同 content-not-clipped，量不裁剪渲染的越界像素",
            "content-clearance": "内容盒左缘 = x0 + t + contentGap(4)；净间隙下限 = contentGap − 0.5pt，不足即红并打印差值",
            "closed-top-straight": "NotchHardware.box 的硬件带；本体墙距 = 闭合宽 − 2t（171），未覆盖的 8pt 必须整体落在硬件矩形内",
            "shelf-peek": "FileShelfLayout：rowHeight 32×3 + rowGap 8×3 + peekHeight 20 = 视口 140",
            "content-bottom-margin": "底部内边距 16（PageMetrics.contentPadding）+ 至多一档 16 = 32；超过 32 说明内容槽比内容高出一整行（本轮新补，专抓底部纯黑）",
            "shape-height": "SPEC §7.2 高度表：首页 148/122/120/107、设置页 166/194/222、文件架 124/124/164/204/232、计时器 107、闭合 32；期望值写死，不从实现反推",
            "height-formula": "SPEC §7.6：H = 92 + C，92 = topInset 36 + chrome 28 + rowSpacing 12 + contentPadding 16；C 只按实际渲染行高求和",
            "page-coverage": "ExpandedItem.allCases 每页至少一个展开态；新 case 不进基线即红",
            "text-fit": "真实文案 + TextKit 按页面真实可用宽度排版；限定行数后可容纳字形数 < 全文字形数即为被省略号截断（判据与 SwiftUI 同源）",
            "fill-face-edges": "SPEC §6.6 / E7：内容盒 23 + 填充面再内缩 4 → 相对形状左缘 27…273、宽 246；像素判据 a=255 且 lum≥8（填充面 10% 白 lum≈26，底色 0），容差 1pt 抗锯齿",
            "files-e7-stability": "SPEC E7 的理由：不改内缩，0↔1 条切换不得左右跳 4pt；判据=虚线框左缘 vs「首行文字墨迹 − 图标20 − 间距8」复原的行布局左缘，差 ≤1pt（4pt 位移会直接超差），且两者都等于内容盒左缘 x0+23±1.5",
            "files-top-anchor": "SPEC §7.6 内容盒顶锚 = topInset 36 + chrome 28 + rowSpacing 12 = 76；files-0 虚线框上缘=76，files-1 的 20pt 图标在 32pt 行内居中 → 上缘 82（行带 76…108）",
            "players-icon-fixture": "基线确定性：设置页列表图标由 PlayerIconFixture 固定为同一占位符号；夹具只改图像内容，不改 16pt 尺寸 / 8pt 间距 / 23 列位置",
        ]
    }

    /// 基线清单里的一个状态。
    private struct BaselineState {
        let name: String
        let open: Bool
        let route: ExpandedItem
        let fixture: MediaFixture
        let shelf: Int
        /// 第三方播放器「已开启」个数，驱动 players 页的子态。
        let playersEnabled: Int
        /// 规范 §7.2 声明的高度：高度不许自己从实现反推，必须对表。
        let specHeight: CGFloat
        let note: String

        /// 首页版式：夹具 → 版式（与 `HomeLayout.resolve` 同源，闭态不参与）。
        var homeLayout: HomeLayout { fixture.homeLayout }
    }

    /// 一页必须覆盖的一个布局子态。
    private struct BaselineSubState {
        /// 状态目录名，与 `--render` 的产物命名保持同一套约定（open-home / open-files-2 …）。
        let name: String
        let fixture: MediaFixture
        let shelf: Int
        let playersEnabled: Int
        /// 规范 §7.2 的声明高度。新增子态必须同时写死这里，否则无法进清单。
        let specHeight: CGFloat
        let note: String
    }

    /// 基线清单的**唯一来源**：展开态由 `ExpandedItem.allCases` × 本函数派生。
    ///
    /// 新增 `ExpandedItem` case 时，下面这个 `switch` 会**编译失败**——这是最强的一道闸：
    /// 作者必须先声明新页的子态才可能编过。运行时再由 `page-coverage` 断言兜住
    /// 「声明为空」与「声明了却没进清单」。
    private func baselineSubStates(for item: ExpandedItem) -> [BaselineSubState] {
        switch item {
        case .home:
            // 首页四种版式高度不同（SPEC §7.2）：播放中 148 / 只有状态 120 / 被拒 120 / 空 107。
            return [
                BaselineSubState(name: "open-home", fixture: .playing, shelf: 0,
                                 playersEnabled: 0, specHeight: 148, note: "首页：播放中"),
                BaselineSubState(name: "open-home-presence", fixture: .presence, shelf: 0,
                                 playersEnabled: 0, specHeight: 120, note: "首页：只有播放状态"),
                BaselineSubState(name: "open-home-empty", fixture: .empty, shelf: 0,
                                 playersEnabled: 0, specHeight: 107, note: "首页：无播放器"),
                BaselineSubState(name: "open-home-denied", fixture: .denied, shelf: 0,
                                 playersEnabled: 0, specHeight: 120, note: "首页：媒体权限被拒"),
            ]
        case .files:
            // 0…4 条各是一个独立布局（行数改变形状高度）；
            // ≥5 夹紧到 4 条 + 滚动，不产生新布局，故不作为独立态。
            // 高度对表（SPEC §7.2）：0/1 = 124、2 = 164、3 = 204、4 = 232。
            let heights: [CGFloat] = [124, 124, 164, 204, 232]
            return (0...4).map { count in
                BaselineSubState(name: "open-files-\(count)", fixture: .none, shelf: count,
                                 playersEnabled: 0, specHeight: heights[count],
                                 note: "文件架：\(count) 条")
            }
        case .timer:
            return [
                BaselineSubState(name: "open-timer", fixture: .none, shelf: 0,
                                 playersEnabled: 0, specHeight: 107, note: "计时器：占位行"),
            ]
        case .players:
            // 0/1/2 个已开启对应三档内容高 74/102/130（SPEC §8.5），是三种不同布局，分别覆盖。
            // 高度对表：166 / 194 / 222。
            return [0, 1, 2].map { enabled in
                BaselineSubState(name: "open-players-\(enabled)", fixture: .none, shelf: 0,
                                 playersEnabled: enabled,
                                 specHeight: [166, 194, 222][enabled],
                                 note: "播放器兼容：第三方已开启 \(enabled) 个")
            }
        }
    }

    /// `--render-baseline[=<dir>]`：固定清单的状态各存一张参考图 + 一份可断言指标。
    ///
    /// 参考图取**自身窗口的窗口服务器合成图**（与 `--capture-demo` 同口径，@2x、632×504px）：
    /// - 不需要屏幕录制权限（只抓自己的窗口），不依赖 `screencapture`，无人工读数；
    /// - 不走 `ImageRenderer`：本机离屏渲染会在 `clipShape` 的 mask 外区域画出
    ///   (255,211,0) 黄色占位块（真机窗口没有），会污染凹角与边缘断言。
    ///
    /// 判据以 **alpha** 为准：形状外 a=0（透出背景）、形状内 a=255 且为黑；
    /// 「内容」= a=255 且亮度 > 60。内容是否被裁由两条互补证据给出：
    /// 1. 合成图里量内容底边到形状底边的余量；
    /// 2. 另渲染一张**不裁剪**的内容图，量内容自然外接矩形是否越过容器底边。
    @MainActor
    private func runBaseline(outputDirectory: String, screen: NSScreen) {
        guard let controller else {
            print("[BASELINE] FAIL controller not created")
            exit(1)
        }
        Task { @MainActor in
            controller.pointerTrackingEnabled = false
            controller.appActivationCollapseEnabled = false
            // 首页高度现在随版式变化（148/120/107），真实媒体轮询必须在抓图期间停止：
            // 否则它异步推来的「当前没在播」会覆盖 .playing 夹具，量到的是空态高度。
            controller.stopMediaForTesting()
            // 设置页列表图标换确定性夹具：真实 app 图标取决于本机装了什么，参考图会跨机器漂移。
            // 夹具只改「画什么图」，16pt 尺寸 / 8pt 间距 / 23 列位置仍由下面这些断言看着。
            PlayerIconFixture.symbolName = PlayerIconFixture.baselineSymbol
            let panel = controller.windowForTesting
            let vm = controller.viewModelForTesting
            let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            // 从头重建：先清空输出目录，避免上一轮的残留文件冒充本轮产物。
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let windowSize = ScreenGeometry.windowSize

            var totalChecks = 0
            var totalFailures = 0
            var index: [[String: Any]] = []
            var captures: [String: NSBitmapImageRep] = [:]

            /// 开合/切页动画约 0.4s，等稳定再抓。
            @MainActor
            func settle() async {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }

            /// 自身窗口的合成图：不需要屏幕录制权限，透明区域保留 alpha。
            @MainActor
            func captureWindow() -> NSBitmapImageRep? {
                guard let image = CGWindowListCreateImage(
                    .null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]
                ) else { return nil }
                return NSBitmapImageRep(cgImage: image)
            }

            /// 连抓两帧、像素完全一致才算稳定：开合/切页是弹簧动画，固定 sleep 会偶尔抓到中间帧
            /// （实测抓过形状右移 45pt、被窗口裁掉一截的帧）。最多重试 10 次。
            /// 还要挡「全透明帧」：窗口尚未重新合成时两帧可能都是空白，连抓一致也会被误采信
            /// （实测 open-files-4 抓到全透明，7 条断言一起红）。至少有一个不透明像素才算有效帧。
            @MainActor
            func hasOpaquePixel(_ rep: NSBitmapImageRep) -> Bool {
                var y = 0
                while y < rep.pixelsHigh {
                    var x = 0
                    while x < rep.pixelsWide {
                        if let a = rep.colorAt(x: x, y: y)?.alphaComponent, a > 0.5 { return true }
                        x += 8
                    }
                    y += 8
                }
                let probe = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
                print("[BASELINE] DEBUG no-opaque \(rep.pixelsWide)x\(rep.pixelsHigh) "
                      + "centerAlpha=\(probe?.alphaComponent ?? -1) "
                      + "visible=\(panel.isVisible) alpha=\(panel.alphaValue) "
                      + "frame=\(panel.frame) number=\(panel.windowNumber) "
                      + "vmOpen=\(vm.isOpen) shape=\(vm.notchSize)")
                return false
            }

            @MainActor
            func captureStable() async -> NSBitmapImageRep? {
                var previous: Data?
                var latest: NSBitmapImageRep?
                for _ in 0..<24 {
                    guard let current = captureWindow(),
                          let png = current.representation(using: .png, properties: [:]) else { return nil }
                    guard hasOpaquePixel(current) else {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }
                    latest = current
                    if previous == png { return current }
                    previous = png
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return latest
            }

            /// 裁一块并放大（最近邻），用于 6x 特写。只写 PNG，指标由调用方写。
            @MainActor
            func writeCloseup(_ rep: NSBitmapImageRep, rectPt: CGRect, scale: CGFloat,
                              upscale: Int, folder: String, name: String) -> Bool {
                let rectPx = CGRect(
                    x: (rectPt.minX * scale).rounded(),
                    y: (rectPt.minY * scale).rounded(),
                    width: (rectPt.width * scale).rounded(),
                    height: (rectPt.height * scale).rounded()
                )
                guard let cg = rep.cgImage?.cropping(to: rectPx) else { return false }
                let w = Int(rectPx.width) * upscale
                let h = Int(rectPx.height) * upscale
                guard let ctx = CGContext(
                    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let out = ctx.makeImage() else { return false }
                let folderURL = dir.appendingPathComponent(folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                guard let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
                else { return false }
                try? png.write(to: folderURL.appendingPathComponent(name))
                return true
            }

            @MainActor
            func writeFolderMetrics(_ folder: String, _ json: [String: Any]) {
                let folderURL = dir.appendingPathComponent(folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    try? d.write(to: folderURL.appendingPathComponent("metrics.json"))
                }
            }

            /// 单个状态的产物与断言。
            @MainActor
            func analyze(_ state: BaselineState) async {
                let stateDir = dir.appendingPathComponent(state.name, isDirectory: true)
                try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
                // 开合状态必须由本函数保证：任何外部关闭都要在这里补回来，否则会抓到闭合帧
                // （实测被「别的 App 激活 → 收起」拍回闭合，17 条断言全红）。
                var forcedState = false
                if state.open != vm.isOpen {
                    if state.open { vm.open() } else { vm.close() }
                    forcedState = true
                    await settle()
                }
                let isOpenNow = vm.isOpen
                let capturedFrame = panel.frame
                guard let rep = await captureStable() else {
                    totalChecks += 1
                    totalFailures += 1
                    print("[BASELINE] FAIL \(state.name) 窗口合成图抓取失败")
                    return
                }
                captures[state.name] = rep
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: stateDir.appendingPathComponent("\(state.name).png"))
                }

                let scale = CGFloat(rep.pixelsWide) / panel.frame.width
                let shape = vm.notchSize
                let x0 = (windowSize.width - shape.width) / 2 + vm.closedBadgeOffset
                let y0: CGFloat = 0
                let radius = vm.topTangentOffset

                func pixel(_ pt: CGPoint) -> (r: Int, g: Int, b: Int, a: Int, lum: Double) {
                    let px = Int((pt.x * scale).rounded())
                    let py = Int((pt.y * scale).rounded())
                    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                          let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
                        return (0, 0, 0, 0, -1)
                    }
                    let r = Int((c.redComponent * 255).rounded())
                    let g = Int((c.greenComponent * 255).rounded())
                    let b = Int((c.blueComponent * 255).rounded())
                    let a = Int((c.alphaComponent * 255).rounded())
                    return (r, g, b, a, 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
                }

                var checks: [(name: String, pass: Bool, detail: String)] = []
                var samples: [[String: Any]] = []

                /// expect: `black`（不透明且黑）/ `clear`（完全透明）/ `notOpaque`（不是不透明黑块）
                func probe(_ name: String, _ pt: CGPoint, expect: String) {
                    let c = pixel(pt)
                    let ok: Bool
                    switch expect {
                    case "black": ok = c.a == 255 && c.lum < 45
                    case "clear": ok = c.a <= 2
                    default: ok = c.a < 250
                    }
                    checks.append((name, ok,
                                   String(format: "rgb=%d,%d,%d a=%d lum=%.0f", c.r, c.g, c.b, c.a, c.lum)))
                    samples.append([
                        "name": name,
                        "x": pt.x,
                        "y": pt.y,
                        "expect": expect,
                        "alpha": c.a,
                        "rgb": [c.r, c.g, c.b],
                        "pass": ok
                    ])
                }

                /// 一条线上的过渡像素：alpha 既不是全透也不是全不透的像素个数。
                func transitions(_ from: CGPoint, _ to: CGPoint) -> Int {
                    let steps = max(1, Int((hypot(to.x - from.x, to.y - from.y) * scale).rounded()))
                    var count = 0
                    for i in 0...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        let pt = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                        let a = pixel(pt).a
                        if a > 10 && a < 245 { count += 1 }
                    }
                    return count
                }

                let midY = y0 + shape.height / 2
                let midX = x0 + shape.width / 2

                // 实测不透明外接：中线一行里 alpha 全不透的最左/最右像素。
                var opaqueLeft = -1.0
                var opaqueRight = -1.0
                let midRow = Int((midY * scale).rounded())
                if midRow >= 0, midRow < rep.pixelsHigh {
                    for px in 0..<rep.pixelsWide {
                        guard let c = rep.colorAt(x: px, y: midRow) else { continue }
                        guard c.alphaComponent > 0.99 else { continue }
                        let ptX = Double(px) / Double(scale)
                        if opaqueLeft < 0 { opaqueLeft = ptX }
                        opaqueRight = ptX
                    }
                }
                // 顶部凹肩：t 是切点偏移（闭合 6 / 展开 19），路径竖直边内缩 t。
                let expectedBodyLeft = x0 + radius
                let expectedBodyRight = x0 + shape.width - radius
                checks.append(("state-open", isOpenNow == state.open,
                               "vm.isOpen=\(isOpenNow) 期望=\(state.open)"))
                checks.append((
                    "shape-position",
                    abs(opaqueLeft - Double(expectedBodyLeft)) <= 1.5
                        && abs(opaqueRight - Double(expectedBodyRight)) <= 1.5,
                    String(format: "实测不透明 %.1f...%.1f 期望 %.1f...%.1f 窗口=%.0f×%.0f",
                           opaqueLeft, opaqueRight, expectedBodyLeft, expectedBodyRight,
                           capturedFrame.width, capturedFrame.height)
                ))
                // 闭合态：形状外是真正的透明（闭合阴影不透明度为 0）；展开态下方与两侧有阴影，
                // 所以展开态的「外部」只能断言「没有被不透明黑块盖住」。
                let outsideExpect = state.open ? "notOpaque" : "clear"
                probe("inside-center", CGPoint(x: midX, y: midY), expect: "black")
                probe("outside-left", CGPoint(x: x0 - 3, y: midY), expect: outsideExpect)
                probe("outside-right", CGPoint(x: x0 + shape.width + 3, y: midY), expect: outsideExpect)
                probe("outside-bottom", CGPoint(x: midX, y: y0 + shape.height + 3), expect: outsideExpect)
                // 顶部两侧：两态都是内凹肩，肩外必须透出背景（t 取当前状态：闭合 6 / 展开 19）。
                let cornerExpect = radius > 0 ? "clear" : "black"
                probe("corner-left", CGPoint(x: x0 + 1, y: y0 + 1), expect: cornerExpect)
                probe("corner-right", CGPoint(x: x0 + shape.width - 1, y: y0 + 1), expect: cornerExpect)
                // 带徽标的闭合态整体加宽、本体左缘不动：实体与右直边采样都必须落在本体上，
                // 不能落到右侧缩略图上。
                let bodyWidth = state.open
                    ? shape.width
                    : min(shape.width, ScreenGeometry.closedSize(for: screen).width)
                probe("solid-left", CGPoint(x: x0 + radius + 2, y: y0 + radius + 2), expect: "black")
                probe("solid-right", CGPoint(x: x0 + bodyWidth - radius - 2, y: y0 + radius + 2),
                      expect: "black")

                // 展开态两侧有阴影（阴影蒙版在顶部 25% 还完全透明），所以把直边测量点放在肩部以下：
                // 那里只有抗锯齿、没有阴影，得到的是纯粹的直边过渡像素数。下沿在展开态一定有阴影，
                // 阈值单独放宽，数值照实记录。
                // 展开态在肩部以下（y = r + 2）量直边：r>0 后 y0+2 仍在肩弧上，
                // 会量到内收量而不是竖直边。该高度仍在阴影蒙版排除的前 25% 内。
                let edgeY = state.open ? y0 + radius + 2 : midY
                let rightEdgeX = state.open ? x0 + shape.width : x0 + bodyWidth
                let edgeLimit = state.open ? 2 : 1
                let bottomLimit = state.open ? 8 : 1
                let leftEdge = transitions(CGPoint(x: x0 - 3, y: edgeY), CGPoint(x: x0 + 3, y: edgeY))
                let rightEdge = transitions(CGPoint(x: rightEdgeX - 3, y: edgeY),
                                            CGPoint(x: rightEdgeX + 3, y: edgeY))
                let bottomEdge = transitions(CGPoint(x: midX, y: y0 + shape.height - 3),
                                             CGPoint(x: midX, y: y0 + shape.height + 3))
                // 顶部肩部（内凹）：在 y = y0 + t/2 这一行水平扫，找第一个不透明黑像素。
                // 二次曲线在该高度上的解析解是 x0 + 0.914t（t 取当前状态：闭合 6 / 展开 19）。
                // 方角（t=0）给 +0；外凸圆弧给 +0.134t。两者都离 0.914t 很远，会红。
                let shoulderY = y0 + radius / 2
                let expectedShoulder = x0 + 0.914 * radius
                /// 在某一行从 x0−3 往右扫，返回第一个不透明黑像素的横坐标（pt）。
                @discardableResult
                func firstOpaqueX(atY y: Double) -> Double {
                    let from = Int(((x0 - 3) * scale).rounded())
                    let to = Int(((x0 + radius + 10) * scale).rounded())
                    guard to > from else { return -1 }
                    for px in from...to {
                        let raw = rep.colorAt(x: px, y: Int((y * scale).rounded()))
                        guard let c = raw?.usingColorSpace(.sRGB) else { continue }
                        let lum = 0.299 * Double(c.redComponent * 255)
                            + 0.587 * Double(c.greenComponent * 255)
                            + 0.114 * Double(c.blueComponent * 255)
                        if Double(c.alphaComponent) * 255 >= 250 && lum < 45 {
                            return Double(px) / Double(scale)
                        }
                    }
                    return -1
                }
                let shoulderFirst = firstOpaqueX(atY: shoulderY)
                let shoulderArc = transitions(
                    CGPoint(x: x0 - 1, y: shoulderY),
                    CGPoint(x: x0 + radius + 2, y: shoulderY)
                )
                checks.append((
                    "shoulder-boundary",
                    shoulderFirst >= 0 && abs(shoulderFirst - Double(expectedShoulder)) <= 1.5,
                    String(format: "y=%.1f 首个不透明 x=%.1f 期望=%.1f（0.914t，t 取当前状态）",
                           shoulderY, shoulderFirst, expectedShoulder)
                ))
                checks.append((
                    "shoulder-arc",
                    shoulderArc >= 1 && shoulderArc <= 4,
                    "过渡像素=\(shoulderArc)（两态都应 1...4）"
                ))
                // 构造证明：肩部轮廓在 y/t = 0.25 / 0.5 / 0.75 处的水平内收量必须落在
                // 二次曲线解析解 t(2√(y/t) − y/t) 上（容差 0.75pt）。
                // 方角会在 0.25 处给 0；外凸圆弧在 0.25 处给 0.339t——只有这条内凹构造能同时对上三点。
                var shoulderFamily: [String] = []
                var shoulderFamilyOK = true
                for fraction in [0.25, 0.5, 0.75] {
                    let y = y0 + radius * fraction
                    let analyticOffset = radius * (2 * fraction.squareRoot() - fraction)
                    let measured = firstOpaqueX(atY: y)
                    let offset = measured >= 0 ? measured - Double(x0) : -1
                    let ok = abs(offset - analyticOffset) <= 0.75
                    shoulderFamilyOK = shoulderFamilyOK && ok
                    shoulderFamily.append(String(
                        format: "y/r=%.2f 内收 %.2f 解析 %.2f%@",
                        fraction, offset, analyticOffset, ok ? "" : " FAIL"
                    ))
                }
                checks.append((
                    "shoulder-family",
                    shoulderFamilyOK,
                    shoulderFamily.joined(separator: "；")
                ))

                checks.append(("edge-left", leftEdge <= edgeLimit,
                               "过渡像素=\(leftEdge)（阈值 \(edgeLimit)）"))
                checks.append(("edge-right", rightEdge <= edgeLimit,
                               "过渡像素=\(rightEdge)（阈值 \(edgeLimit)）"))
                checks.append(("edge-bottom", bottomEdge <= bottomLimit,
                               "过渡像素=\(bottomEdge)（阈值 \(bottomLimit)）"))

                // 内容不被裁（合成图）：形状内缩 2pt 扫亮像素，量内容底边到形状底边的余量。
                let budget = PageMetrics.heightBudget(
                    for: state.route,
                    shelfCount: state.shelf,
                    home: state.homeLayout,
                    playersEnabled: state.playersEnabled
                )
                let naturalShape = budget.total
                let shapeDelta = naturalShape - shape.height
                let inset: CGFloat = 2
                var contentTop = -1.0
                var contentBottom = -1.0
                var contentLeft = -1.0
                var contentRight = -1.0
                let cx0 = Int(((x0 + inset) * scale).rounded())
                let cx1 = Int(((x0 + shape.width - inset) * scale).rounded())
                let cy0 = Int(((y0 + inset) * scale).rounded())
                let cy1 = Int(((y0 + shape.height - inset) * scale).rounded())
                if cx1 > cx0, cy1 > cy0 {
                    for py in cy0...cy1 {
                        for px in cx0...cx1 {
                            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                            guard Double(c.alphaComponent) * 255 >= 250 else { continue }
                            let lum = 0.299 * Double(c.redComponent * 255)
                                + 0.587 * Double(c.greenComponent * 255)
                                + 0.114 * Double(c.blueComponent * 255)
                            guard lum > 60 else { continue }
                            let ptX = Double(px) / Double(scale)
                            let ptY = Double(py) / Double(scale)
                            if contentTop < 0 || ptY < contentTop { contentTop = ptY }
                            if ptY > contentBottom { contentBottom = ptY }
                            if contentLeft < 0 || ptX < contentLeft { contentLeft = ptX }
                            if ptX > contentRight { contentRight = ptX }
                        }
                    }
                }
                let bottomMargin = contentBottom < 0 ? -1 : (y0 + shape.height) - contentBottom

                // 内容左侧净间隙：内容最早像素到「侧壁」（x0 + t）的距离，必须 ≥ contentGap(4)。
                // 展开态内容盒左缘 = x0 + t + 4（t=19 → 23），所以净间隙应 ≈ 4；
                // 旧实现固定 16 时内容盒左缘 = x0 + 16 < 侧壁 x0 + 19，实测被裁到 x0 + 19。
                let wallX = Double(x0 + radius)
                let clearanceFloor = Double(NotchHardware.contentGap)
                let leftClearance = contentLeft < 0 ? -1 : contentLeft - wallX
                let clearanceApplicable = state.open || contentLeft >= 0
                let clearancePass = !clearanceApplicable || leftClearance >= clearanceFloor - 0.5
                let clearanceDetail: String
                if !clearanceApplicable {
                    clearanceDetail = "闭合态无内容像素，不适用"
                } else if clearancePass {
                    clearanceDetail = String(
                        format: "内容左缘=%.1f 侧壁=%.1f 净间隙=%.1fpt（下限 %.1f）",
                        contentLeft, wallX, leftClearance, clearanceFloor
                    )
                } else {
                    clearanceDetail = String(
                        format: "内容左缘=%.1f 侧壁=%.1f 净间隙=%.1fpt 差 %.1fpt（下限 %.1f）",
                        contentLeft, wallX, leftClearance,
                        clearanceFloor - leftClearance, clearanceFloor
                    )
                }
                checks.append(("content-clearance", clearancePass, clearanceDetail))

                // 闭合态顶部直边：t 在顶边两侧各切掉 t，本体墙距 = 宽 − 2t = 183−12 = 171，
                // 比硬件带 179 窄 8pt（每侧 4pt）。这 8pt 不被面板覆盖，但必须整体落在硬件矩形内
                // （物理刘海遮住 → 不可见）。若 t 大于本体相对硬件带的外扩量（当前 2pt），
                // 透明楔形就会漏到硬件带之外、真的露出桌面背景，这里会红。
                var hardwareBandInfo: [String: Any] = [:]
                // 只在「不带徽标」的闭合态量：带徽标时形状整体向右加宽（211），右墙移到
                // 本体之外，左右不再对称，这条对硬件带的比较没有意义。
                if !state.open, vm.closedBadgeOffset == 0,
                   let bandBox = NotchHardware.box(for: ScreenGeometry.Metrics.from(screen)) {
                    let bodyWidth = Double(min(shape.width, ScreenGeometry.closedSize(for: screen).width))
                    let hwLeft = Double(bandBox.rect.minX - capturedFrame.minX)
                    let hwRight = Double(bandBox.rect.maxX - capturedFrame.minX)
                    let probeY = Double(y0 + radius + 1)
                    let probeRow = Int((probeY * scale).rounded())
                    let scanFrom = Int(((x0 - 2) * scale).rounded())
                    let scanTo = Int(((x0 + bodyWidth + 2) * scale).rounded())
                    var wallL = -1.0
                    var wallR = -1.0
                    if probeRow >= 0, probeRow < rep.pixelsHigh {
                        let lo = max(0, scanFrom)
                        let hi = min(rep.pixelsWide - 1, scanTo)
                        if hi > lo {
                            for px in lo...hi {
                                guard let c = rep.colorAt(x: px, y: probeRow),
                                      c.alphaComponent > 0.99 else { continue }
                                let pt = Double(px) / Double(scale)
                                if wallL < 0 { wallL = pt }
                                wallR = pt
                            }
                        }
                    }
                    // 顶部 0…t：带内透明像素=透出背景的肩部楔形；带外的那几列是 2pt 抗锯齿外扩。
                    var clearTop = 0
                    var clearOutsideBand = 0
                    let topRows = max(1, Int((radius * scale).rounded()))
                    let bandFrom = Int((hwLeft * scale).rounded())
                    let bandTo = Int((hwRight * scale).rounded())
                    let topLo = max(0, scanFrom)
                    let topHi = min(rep.pixelsWide - 1, scanTo)
                    if topHi > topLo {
                        for py in 0..<min(topRows, rep.pixelsHigh) {
                            for px in topLo...topHi {
                                guard let c = rep.colorAt(x: px, y: py),
                                      c.alphaComponent <= 0.02 else { continue }
                                clearTop += 1
                                if px < bandFrom || px > bandTo { clearOutsideBand += 1 }
                            }
                        }
                    }
                    let straight = wallR - wallL
                    let bandWidth = hwRight - hwLeft
                    let leftUncovered = wallL - hwLeft
                    let rightUncovered = hwRight - wallR
                    let bandPass = wallL >= hwLeft - 0.5 && wallR <= hwRight + 0.5
                        && abs(straight - (bodyWidth - 2 * Double(radius))) <= 0.5
                    checks.append((
                        "closed-top-straight",
                        bandPass,
                        String(format: "本体墙距 %.1fpt（%.0f − 2×%.0f），硬件带 %.1fpt；左右未覆盖 %.1f/%.1fpt 全在硬件矩形内；顶部 0…%.0fpt 透明像素：带内 %d、带外 %d（采样窗外扩 2pt + 本体外扩 2pt）",
                               straight, bodyWidth, radius, bandWidth,
                               leftUncovered, rightUncovered, radius,
                               clearTop - clearOutsideBand, clearOutsideBand)
                    ))
                    hardwareBandInfo = [
                        "straightWallPt": straight,
                        "bodyWidthPt": bodyWidth,
                        "hardwareWidthPt": bandWidth,
                        "wallLeftPt": wallL,
                        "wallRightPt": wallR,
                        "hardwareLeftPt": hwLeft,
                        "hardwareRightPt": hwRight,
                        "uncoveredLeftPt": leftUncovered,
                        "uncoveredRightPt": rightUncovered,
                        "topRowsScanned": topRows,
                        "clearPixelsInTopBand": clearTop,
                        "clearPixelsOutsideBand": clearOutsideBand,
                        "probeYPt": probeY,
                        "note": "未被面板覆盖的 8pt（每侧 4pt）全在硬件矩形内；抓帧里这些像素 a=0（背景），物理上被刘海遮住"
                    ]
                }

                // 展开态的真实余量取自下面那张「不裁剪」渲染：合成图里暗色内容（进度条、
                // 次级文案）亮度可能低于 60，量到的底边会偏高。/ 闭合态没有页面内容，不做比较。
                var naturalMargin: Double?

                // 内容不被裁（不裁剪渲染）：内容自然外接矩形是否越过容器底边。
                var overflowInfo: [String: Any] = [:]
                if state.open {
                    FileShelfRendering.isOffscreen = true
                    let overflowRep = renderCanvas(
                        open: true, route: state.route, fixture: state.fixture,
                        shelfCount: state.shelf, screen: screen, withMarker: false,
                        scale: 2, showsShape: false, canvasBackground: .black
                    )
                    FileShelfRendering.isOffscreen = false
                    if let orep = overflowRep {
                        if let png = orep.representation(using: .png, properties: [:]) {
                            try? png.write(to: stateDir.appendingPathComponent("\(state.name)-content.png"))
                        }
                        let oscale: CGFloat = 2
                        let ox0 = 40 + (windowSize.width - shape.width) / 2 + vm.closedBadgeOffset
                        let oy0: CGFloat = 40
                        var naturalTop = -1.0
                        var naturalBottom = -1.0
                        var naturalLeft = -1.0
                        var naturalRight = -1.0
                        var outside = 0
                        var outsideRows: [Int] = []
                        let wx0 = Int((40 * oscale).rounded())
                        let wx1 = Int(((40 + windowSize.width) * oscale).rounded())
                        let wy0 = Int((oy0 * oscale).rounded())
                        let wy1 = Int(((40 + windowSize.height) * oscale).rounded())
                        for py in wy0..<max(wy0, wy1) {
                            for px in wx0..<max(wx0, wx1) {
                                guard let c = orep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                                let lum = 0.299 * Double(c.redComponent * 255)
                                    + 0.587 * Double(c.greenComponent * 255)
                                    + 0.114 * Double(c.blueComponent * 255)
                                guard lum > 60 else { continue }
                                let ptX = Double(px) / Double(oscale)
                                let ptY = Double(py) / Double(oscale) - Double(oy0)
                                if naturalTop < 0 || ptY < naturalTop { naturalTop = ptY }
                                if ptY > naturalBottom { naturalBottom = ptY }
                                if naturalLeft < 0 || ptX < naturalLeft { naturalLeft = ptX }
                                if ptX > naturalRight { naturalRight = ptX }
                                let overBottom = ptY > Double(shape.height) + 0.25
                                let overSide = ptX < Double(ox0) - 0.25
                                    || ptX > Double(ox0 + shape.width) + 0.25
                                if overBottom || overSide {
                                    outside += 1
                                    if outsideRows.count < 6 { outsideRows.append(py) }
                                }
                            }
                        }
                        let unclippedMargin = shape.height - naturalBottom
                        naturalMargin = unclippedMargin
                        overflowInfo = [
                            "naturalTopPt": naturalTop,
                            "naturalBottomPt": naturalBottom,
                            "naturalLeftPt": naturalLeft,
                            "naturalRightPt": naturalRight,
                            "containerBottomPt": shape.height,
                            "naturalMarginPt": unclippedMargin,
                            "outsidePixels": outside,
                            "outsideRowsPx": outsideRows
                        ]
                        let overflowPass = outside == 0
                        checks.append((
                            "content-overflow",
                            overflowPass,
                            String(format: "越界像素=%d 自然内容底=%.1f 容器底=%.1f 余量=%.1fpt",
                                   outside, naturalBottom, shape.height, unclippedMargin)
                        ))
                        if !overflowPass {
                            let rows = outsideRows.map { String(format: "%.1f", Double($0) / 2 - 40) }
                            print("[BASELINE] FAIL \(state.name) content-overflow 被越界元素=\(state.route == .files ? "文件架行" : "页面内容块") 像素行 y=\(rows.joined(separator: ","))pt")
                        }
                    } else {
                        checks.append(("content-overflow", false, "不裁剪渲染失败"))
                    }
                }

                // 内容不被裁：展开态的判据 = 自然高度不超容器 + 不裁剪渲染的底边余量 >= 0；
                // 闭合态没有页面内容，只要求内容底边余量 >= 0。
                let clipPass: Bool
                let clipDetail: String
                if state.open {
                    let margin = naturalMargin ?? bottomMargin
                    clipPass = shapeDelta <= 0.01 && margin >= 0
                    clipDetail = String(
                        format: "自然=%.1f 容器=%.1f 差=%.1f 不裁剪内容底边余量=%.1fpt",
                        naturalShape, shape.height, shapeDelta, margin
                    )
                } else {
                    clipPass = contentBottom < 0 || bottomMargin >= 0
                    clipDetail = contentBottom < 0
                        ? "闭合态无页面内容，不做自然/容器比较"
                        : String(format: "闭合态，不做自然/容器比较；内容底边余量=%.1fpt", bottomMargin)
                }
                checks.append(("content-not-clipped", clipPass, clipDetail))

                // 底部余量**上限**：内容底到面板底不允许空出超过一个 lg 控件档位。
                // 口径 = 底部内边距 16（PageMetrics.contentPadding）+ 至多一档 16 → 32。
                // 超过即意味着内容槽比内容高出一整行——正是设置页 54.5pt 纯黑那类缺陷。
                // 只判下限的 content-not-clipped 永远抓不到它（这是上一轮真正的漏洞）。
                let bottomCeiling = DesignSystem.Control.lg
                let ceilingMargin = state.open ? (naturalMargin ?? bottomMargin) : bottomMargin
                let ceilingPass = ceilingMargin < 0 || ceilingMargin <= bottomCeiling
                checks.append((
                    "content-bottom-margin",
                    ceilingPass,
                    ceilingMargin < 0
                        ? "闭合态无内容像素，不适用"
                        : String(format: "内容底到面板底=%.1fpt 上限=%.0fpt 超出=%.1fpt",
                                 ceilingMargin, bottomCeiling,
                                 max(0, ceilingMargin - bottomCeiling))
                ))

                // 规范表高度：H 只能取 §7.2 声明的值（148/122/120/107/166/194/222 …）。
                // 期望值来自规范表，不从实现反推；实现改高度会在这里红。
                let heightOff = abs(shape.height - state.specHeight)
                checks.append((
                    "shape-height",
                    heightOff <= 0.5,
                    String(format: "实测 %.0f 规范表 %.0f 差 %.1f", shape.height, state.specHeight, heightOff)
                ))
                // H = 92 + C：C 只按实际渲染行高求和（展开态）。闭合态没有页面内容，不适用。
                if state.open {
                    let formulaOff = abs(state.specHeight - (PageMetrics.fixedOverhead + budget.content))
                    checks.append((
                        "height-formula",
                        formulaOff <= 0.5,
                        String(format: "规范表 %.0f = %.0f + C%.0f（实测 %.0f）",
                               state.specHeight, PageMetrics.fixedOverhead, budget.content, shape.height)
                    ))
                }

                // E7 填充面：设置页入口按钮是当前唯一的「整行持久填充面」。
                // **坐标口径**：下面所有 x 都相对**形状左缘** x0（窗口坐标 8，因为 300 宽形状居中于 316 窗口）。
                // 规范 §6.6 / E7 的 27…273 就是这个口径：内容盒 23 + 填充面再内缩 4 = 27，右缘 300−27 = 273，
                // 宽 246。换算成窗口坐标是 35…281。
                // 量法：取按钮竖直中心那一行（圆角已退出该行，左右是竖直边），
                // 判据 = alpha 255 且 lum ≥ 8 的最左/最右像素。填充面 10% 白压在纯黑上 lum≈26，
                // 面板底色 lum=0，所以 8 只可能落在填充面上（抗锯齿半像素也高于它）。
                // 容差 1pt：@2x 下一个像素是 0.5pt，边缘最多吃掉半个像素。
                var fillFaceInfo: [String: Any] = [:]
                if state.route == .players {
                    checks.append((
                        "players-icon-fixture",
                        PlayerIconFixture.symbolName == PlayerIconFixture.baselineSymbol,
                        "图标来源=\(PlayerIconFixture.symbolName ?? "生产路径（真实 app 图标）")；"
                            + "夹具固定 16pt，尺寸/列位置与生产一致"
                    ))
                    let contentTopPt = PageMetrics.topInset + PageMetrics.chromeHeight
                        + PageMetrics.rowSpacing
                    let buttonTop = contentTopPt + budget.content - DesignSystem.Control.md
                    let probeYPt = buttonTop + DesignSystem.Control.md / 2
                    let probeRow = Int((probeYPt * scale).rounded())
                    var fillLeft = -1.0
                    var fillRight = -1.0
                    let scanFrom = max(0, Int(((x0 + 1) * scale).rounded()))
                    let scanTo = min(rep.pixelsWide - 1, Int(((x0 + shape.width - 1) * scale).rounded()))
                    if probeRow >= 0, probeRow < rep.pixelsHigh, scanTo > scanFrom {
                        for px in scanFrom...scanTo {
                            guard let c = rep.colorAt(x: px, y: probeRow)?.usingColorSpace(.sRGB) else { continue }
                            guard Double(c.alphaComponent) * 255 >= 250 else { continue }
                            let lum = 0.299 * Double(c.redComponent * 255)
                                + 0.587 * Double(c.greenComponent * 255)
                                + 0.114 * Double(c.blueComponent * 255)
                            guard lum >= 8 else { continue }
                            let ptX = Double(px) / Double(scale)
                            if fillLeft < 0 { fillLeft = ptX }
                            fillRight = ptX
                        }
                    }
                    let leftRel = fillLeft < 0 ? -1 : fillLeft - Double(x0)
                    let rightRel = fillRight < 0 ? -1 : fillRight - Double(x0)
                    // 最右像素的中心在 273 内半个像素处，所以宽度用「右缘 − 左缘 + 1px」复原。
                    let fillWidth = fillLeft < 0 ? -1 : fillRight - fillLeft + 1 / Double(scale)
                    let tolerance = 1.0
                    let fillPass = fillLeft >= 0
                        && abs(leftRel - 27) <= tolerance
                        && abs(rightRel - 273) <= tolerance
                    checks.append((
                        "fill-face-edges",
                        fillPass,
                        String(
                            format: "填充面左缘=%.1f 右缘=%.1f（相对形状左缘；规范 27/273，容差 %.1f）；"
                                + "窗口坐标 %.1f…%.1f；宽=%.1f（规范 246）；探针行 y=%.1f",
                            leftRel, rightRel, tolerance, fillLeft, fillRight, fillWidth, probeYPt
                        )
                    ))
                    fillFaceInfo = [
                        "leftPtRelativeToShape": leftRel,
                        "rightPtRelativeToShape": rightRel,
                        "leftPtWindow": fillLeft,
                        "rightPtWindow": fillRight,
                        "widthPt": fillWidth,
                        "probeYPt": probeYPt,
                        "tolerancePt": tolerance,
                        "note": "坐标相对形状左缘；窗口坐标 = +8（316 窗口内 300 宽形状居中）"
                    ]
                }

                // 文件架：4 条时要有 20pt 提示位（上限被压下去时这里会先掉）。
                var shelfInfo: [String: Any] = [:]
                if state.route == .files {
                    let skeleton = budget.overhead + budget.chrome
                    let viewport = shape.height - skeleton
                    let peek = viewport - (FileShelfLayout.rowHeight * 3 + FileShelfLayout.rowGap * 3)
                    shelfInfo = ["viewportPt": viewport, "peekPt": peek]
                    if state.shelf >= 4 {
                        checks.append((
                            "shelf-peek",
                            peek >= FileShelfLayout.peekHeight - 0.5,
                            String(format: "视口=%.1f 提示位=%.1f（应 %.0f）",
                                   viewport, peek, FileShelfLayout.peekHeight)
                        ))
                    }
                }

                for check in checks {
                    totalChecks += 1
                    if !check.pass { totalFailures += 1 }
                    print("[BASELINE] \(check.pass ? "PASS" : "FAIL") \(state.name) \(check.name)  \(check.detail)")
                }

                let metrics: [String: Any] = [
                    "state": state.name,
                    "note": state.note,
                    "open": state.open,
                    "route": String(describing: state.route),
                    "shelfCount": state.shelf,
                    "capture": ["width": rep.pixelsWide, "height": rep.pixelsHigh, "scale": scale,
                                "source": "own-window-composite"],
                    "panelFrame": ["x": capturedFrame.minX, "y": capturedFrame.minY,
                                   "width": capturedFrame.width, "height": capturedFrame.height],
                    "vmIsOpen": isOpenNow,
                    "forcedState": forcedState,
                    "measuredOpaque": ["leftPt": opaqueLeft, "rightPt": opaqueRight],
                    "windowOrigin": ["x": 0, "y": 0, "width": windowSize.width, "height": windowSize.height],
                    "shape": ["x": x0, "y": y0, "width": shape.width, "height": shape.height],
                    "corner": ["topTangentOffset": radius, "bottomTangentOffset": vm.bottomTangentOffset,
                               "semantics": "切点偏移 t，不是 cornerRadius"],
                    "content": [
                        "naturalShapeHeight": naturalShape,
                        "naturalApplicable": state.open,
                        "containerShapeHeight": shape.height,
                        "delta": shapeDelta,
                        "measuredTopPt": contentTop,
                        "measuredBottomPt": contentBottom,
                        "measuredLeftPt": contentLeft,
                        "measuredRightPt": contentRight,
                        "measuredBottomMarginPt": bottomMargin,
                        "wallLeftPt": wallX,
                        "leftClearancePt": leftClearance,
                        "leftClearanceFloorPt": clearanceFloor,
                        "leftClearanceApplicable": clearanceApplicable
                    ],
                    "hardwareBand": hardwareBandInfo,
                    "overflow": overflowInfo,
                    "fillFace": fillFaceInfo,
                    "shelf": shelfInfo,
                    "edges": ["leftTransitions": leftEdge, "rightTransitions": rightEdge,
                              "bottomTransitions": bottomEdge],
                    "shoulder": ["scanYPt": shoulderY, "firstOpaqueXPt": shoulderFirst,
                                 "expectedXPt": expectedShoulder,
                                 "transitions": shoulderArc,
                                 "family": shoulderFamily,
                                 "source": "形状来源=auxiliaryTopLeft/RightArea + safeAreaInsets.top 给出的硬件带 179×32；顶部 t 取当前状态（闭合 6 / 展开 19），来源=参照实现，绝对值未实测（见 ScreenGeometry.shoulderTangentOffset）"],
                    "samples": samples,
                    "assertionSources": AssertionSources.map,
                    "checks": checks.map { ["name": $0.name, "pass": $0.pass, "detail": $0.detail] }
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: metrics,
                    options: [.prettyPrinted, .sortedKeys]
                ) {
                    try? data.write(to: stateDir.appendingPathComponent("metrics.json"))
                }
                index.append(["state": state.name, "path": state.name, "checks": checks.count,
                              "failures": checks.filter { !$0.pass }.count])
            }

            // 1) 清单派生：闭合态单独声明（它们不属于任何页面），展开态全部由 allCases 派生。
            let closedStates = [
                BaselineState(name: "closed-idle", open: false, route: .home, fixture: .none,
                              shelf: 0, playersEnabled: 0, specHeight: 32, note: "闭合态，无媒体"),
                BaselineState(name: "closed-playing", open: false, route: .home, fixture: .playing,
                              shelf: 0, playersEnabled: 0, specHeight: 32, note: "闭合态，播放中（右侧缩略图位）"),
                BaselineState(name: "closed-presence", open: false, route: .home, fixture: .presence,
                              shelf: 0, playersEnabled: 0, specHeight: 32, note: "闭合态，只有播放状态（IOPM 通道）"),
            ]
            var states = closedStates
            for item in ExpandedItem.allCases {
                for sub in baselineSubStates(for: item) {
                    states.append(BaselineState(
                        name: sub.name, open: true, route: item,
                        fixture: sub.fixture, shelf: sub.shelf,
                        playersEnabled: sub.playersEnabled, specHeight: sub.specHeight,
                        note: sub.note
                    ))
                }
            }

            // 2) 派生完备性：allCases 的每一页都必须至少有一个展开态进基线。
            //    放在抓帧之前——「新增了页面但没进基线」不必等整轮跑完才暴露。
            for item in ExpandedItem.allCases {
                totalChecks += 1
                let covered = states.filter { $0.open && $0.route == item }
                if covered.isEmpty {
                    totalFailures += 1
                    print("[BASELINE] FAIL page-coverage \(item.rawValue) 没有任何展开态进入基线")
                } else {
                    print("[BASELINE] PASS page-coverage \(item.rawValue) \(covered.count) 态："
                          + covered.map(\.name).joined(separator: ", "))
                }
            }
            // 名字重复会让后一个状态覆盖前一个的产物目录，静默丢态。
            let duplicatedNames = Dictionary(grouping: states, by: \.name)
                .filter { $0.value.count > 1 }.keys.sorted()
            totalChecks += 1
            if duplicatedNames.isEmpty {
                print("[BASELINE] PASS state-unique \(states.count) 态，名字无重复")
            } else {
                totalFailures += 1
                print("[BASELINE] FAIL state-unique 重复：\(duplicatedNames.joined(separator: ", "))")
            }

            // 2.5) 文案截断：用**真实字符串**按页面的真实可用宽度做 TextKit 排版。
            //      判据与 SwiftUI 同源：限定 maximumNumberOfLines 后，能容纳的字形数
            //      少于全文字形数，尾部就被省略号替换。
            //      `maxLines` 同时是**文案表声明的档位**：不限行排版的实际行数必须等于它。
            //      单行档长出两行 = 文字被裁；双行档只有一行 = 底部多 15pt 真空；两个方向都会红。
            //      这条与「底部余量上限」是两回事，数值分开记：前者量文字宽度/行数，后者量内容底到面板底。
            func textFit(_ label: String, _ text: String, style: DesignSystem.TextStyle,
                         width: CGFloat, maxLines: Int) {
                let nsWeight: NSFont.Weight = style.weight == .semibold ? .semibold : .regular
                let font = NSFont.systemFont(ofSize: style.size, weight: nsWeight)
                let attributed = NSAttributedString(string: text, attributes: [.font: font])
                let storage = NSTextStorage(attributedString: attributed)
                let layout = NSLayoutManager()
                let container = NSTextContainer(
                    size: CGSize(width: width, height: .greatestFiniteMagnitude)
                )
                container.lineFragmentPadding = 0
                container.maximumNumberOfLines = maxLines
                container.lineBreakMode = .byTruncatingTail
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                layout.ensureLayout(for: container)
                let visible = layout.glyphRange(for: container).length
                let truncated = visible < layout.numberOfGlyphs
                // 不限行再排一遍：数自然行数，核对「声明档位 == 实际行数」。
                let measureStorage = NSTextStorage(attributedString: attributed)
                let measureLayout = NSLayoutManager()
                let measureContainer = NSTextContainer(
                    size: CGSize(width: width, height: .greatestFiniteMagnitude)
                )
                measureContainer.lineFragmentPadding = 0
                measureContainer.maximumNumberOfLines = 0
                measureLayout.addTextContainer(measureContainer)
                measureStorage.addLayoutManager(measureLayout)
                measureLayout.ensureLayout(for: measureContainer)
                var lineCount = 0
                var glyph = 0
                while glyph < measureLayout.numberOfGlyphs {
                    var lineRange = NSRange()
                    _ = measureLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                    glyph = max(NSMaxRange(lineRange), glyph + 1)
                    lineCount += 1
                }
                let natural = attributed.size()
                totalChecks += 1
                if truncated || lineCount != maxLines {
                    totalFailures += 1
                    let reason = truncated
                        ? "会被省略号截断"
                        : "声明 \(maxLines) 行、实际 \(lineCount) 行"
                    print(String(format: "[BASELINE] FAIL text-fit %@ %@：需要宽 %.1f 可用 %.1f（；%@）",
                                 label, reason, natural.width, width, text))
                } else {
                    print(String(format: "[BASELINE] PASS text-fit %@ 不截断且行数对上：需要宽 %.1f 可用 %.1f 余 %.1f（声明 %d 行/实际 %d 行；%@）",
                                 label, natural.width, width, width - natural.width,
                                 maxLines, lineCount, text))
                }
            }
            let homeTextWidth = ExpandedItem.home.contentSize.width
            let playersTextWidth = ExpandedItem.players.contentSize.width
            // 「权限被拒」那行左右各有图标：16 + 8 + 文字 + 8 + 16。
            let guideTextWidth = homeTextWidth
                - DesignSystem.Size.icon * 2 - DesignSystem.Spacing.sm * 2
            // 只有播放状态：图标 16 + 8 + 主文字（右侧提示在 254 宽下整块隐藏）。
            let presenceTextWidth = homeTextWidth - DesignSystem.Size.icon - DesignSystem.Spacing.sm
            // 设置页列表：图标 16 + 8 + 名称。
            let listTextWidth = playersTextWidth - DesignSystem.Size.icon - DesignSystem.Spacing.sm
            // 设置页按钮：整行填充面再内缩 4（E7）。
            let buttonTextWidth = playersTextWidth - DesignSystem.Spacing.xs * 2
            textFit("home-empty", HomeCopyTable.emptyText,
                    style: DesignSystem.Typography.body, width: homeTextWidth, maxLines: HomeCopyTable.emptyLines)
            textFit("home-denied", HomeCopyTable.deniedText,
                    style: DesignSystem.Typography.body, width: guideTextWidth, maxLines: HomeCopyTable.deniedLines)
            textFit("home-presence", "网易云音乐 · 正在播放",
                    style: DesignSystem.Typography.body, width: presenceTextWidth, maxLines: 1)
            textFit("players-system-line", "系统播放器：Music、Spotify（恒开）",
                    style: DesignSystem.Typography.body, width: playersTextWidth, maxLines: 1)
            textFit("players-thirdparty-line", "第三方 5/5 已开启 · 默认关闭",
                    style: DesignSystem.Typography.body, width: playersTextWidth, maxLines: 1)
            textFit("players-list-name", "YouTube Music",
                    style: DesignSystem.Typography.body, width: listTextWidth, maxLines: 1)
            textFit("players-more-line", "另有 4 个已开启",
                    style: DesignSystem.Typography.body, width: listTextWidth, maxLines: 1)
            textFit("players-button", "打开播放器设置…",
                    style: DesignSystem.Typography.body, width: buttonTextWidth, maxLines: 1)

            // 3) 逐个状态跑：每个状态自己重建前置条件，不依赖上一个状态的残留。
            //    播放器开关是真的 UserDefaults，先存原值、跑完恢复，不留副作用。
            let originalPlayersEnabled = PlayerRegistry.entries
                .filter(\.isThirdParty)
                .map { ($0.bundleID, PlayerRegistry.isEnabled($0.bundleID)) }
            for state in states {
                vm.clearShelf()
                let shelfFiles = makeShelfFixtureFiles(count: state.shelf)
                if !shelfFiles.isEmpty { vm.addShelfFiles(shelfFiles) }
                for (index, entry) in PlayerRegistry.entries.filter(\.isThirdParty).enumerated() {
                    PlayerRegistry.setEnabled(index < state.playersEnabled, for: entry.bundleID)
                }
                vm.reloadPlayerSettings()
                // 先归零再套夹具：`.none` 夹具本身不写状态，不归零会把上一页的媒体带过来。
                vm.applyMedia(.none, permission: .granted)
                applyFixture(state.fixture, to: vm)
                vm.select(state.route)
                await settle()
                await analyze(state)
            }

            // 4) E7 的反例证明（像素）：文件架 0 条 ↔ 1 条切换时，虚线框与首行必须落在同一条左缘上。
            //    规范给 E7 的理由正是「不改内缩，否则切换时整行左右跳 4pt」；这里把「不跳」钉成断言。
            //    顺带用两条独立证据确认内容盒顶锚一致：
            //    files-0 的虚线框上缘就画在内容盒顶 76；files-1 的 20pt 图标在 32pt 行内居中 → 上缘 82（行带 76…108）。
            do {
                let filesWidth = PageMetrics.shapeSize(for: .files, shelfCount: 0).width
                let filesX0 = (windowSize.width - filesWidth) / 2
                let contentTopPt = PageMetrics.topInset + PageMetrics.chromeHeight
                    + PageMetrics.rowSpacing
                // files 0/1 的规范高度都是 124；内容带只取到「面板底 − 底部内边距」，排除底部留白。
                let filesSpecHeight: CGFloat = 124
                let bandBottomPt = filesSpecHeight - PageMetrics.contentPadding

                /// 内容带里 x∈[fromX, toX] 的最左墨迹（a=255 且 lum≥8；面板底色 lum=0）。
                func inkLeft(_ name: String, fromX: Double, toX: Double) -> Double? {
                    guard let rep = captures[name] else { return nil }
                    let s = CGFloat(rep.pixelsWide) / panel.frame.width
                    let yFrom = Int((contentTopPt * s).rounded())
                    let yTo = Int((bandBottomPt * s).rounded())
                    let xFrom = max(0, Int((fromX * s).rounded()))
                    let xTo = min(rep.pixelsWide - 1, Int((toX * s).rounded()))
                    guard yTo > yFrom, xTo > xFrom else { return nil }
                    var left = -1.0
                    for py in yFrom...yTo {
                        for px in xFrom...xTo {
                            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                            guard Double(c.alphaComponent) * 255 >= 250 else { continue }
                            let lum = 0.299 * Double(c.redComponent * 255)
                                + 0.587 * Double(c.greenComponent * 255)
                                + 0.114 * Double(c.blueComponent * 255)
                            guard lum >= 8 else { continue }
                            let ptX = Double(px) / Double(s)
                            if left < 0 || ptX < left { left = ptX }
                        }
                    }
                    return left < 0 ? nil : left
                }

                /// 在内容带里找最左/最上/最下的墨迹（同上判据）。
                func inkExtent(_ name: String) -> (left: Double, top: Double, bottom: Double)? {
                    guard let rep = captures[name] else { return nil }
                    let s = CGFloat(rep.pixelsWide) / panel.frame.width
                    let yFrom = Int((contentTopPt * s).rounded())
                    let yTo = Int((bandBottomPt * s).rounded())
                    let xFrom = max(0, Int(((filesX0 + 1) * s).rounded()))
                    let xTo = min(rep.pixelsWide - 1,
                                  Int(((filesX0 + filesWidth - 1) * s).rounded()))
                    guard yTo > yFrom, xTo > xFrom else { return nil }
                    var left = -1.0
                    var top = -1.0
                    var bottom = -1.0
                    for py in yFrom...yTo {
                        for px in xFrom...xTo {
                            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                            guard Double(c.alphaComponent) * 255 >= 250 else { continue }
                            let lum = 0.299 * Double(c.redComponent * 255)
                                + 0.587 * Double(c.greenComponent * 255)
                                + 0.114 * Double(c.blueComponent * 255)
                            guard lum >= 8 else { continue }
                            let ptX = Double(px) / Double(s)
                            let ptY = Double(py) / Double(s)
                            if left < 0 || ptX < left { left = ptX }
                            if top < 0 || ptY < top { top = ptY }
                            if ptY > bottom { bottom = ptY }
                        }
                    }
                    return left < 0 ? nil : (left, top, bottom)
                }

                let emptyInk = inkExtent("open-files-0")
                let oneInk = inkExtent("open-files-1")
                let expectedLeft = Double(filesX0) + Double(PageMetrics.openContentHorizontalInset)

                // files-0 直接量虚线框左缘；files-1 不能直接量首行墨迹——
                // 20pt 的 app 图标自带透明边（下面 top-anchor 也量到顶部缩 1pt），
                // 直接比会把「图标内边距」当成布局位移。所以跳过图标列量到**文字**左缘，
                // 再减去「图标 20 + 间距 8」复原这一行的布局左缘（文字会有 ≤1pt 的字形左边距）。
                let iconColumn = Double(PageMetrics.openContentHorizontalInset)
                    + Double(DesignSystem.Size.fileIcon)
                let dashLeft = inkLeft("open-files-0",
                                       fromX: Double(filesX0) + 1,
                                       toX: Double(filesX0 + filesWidth - 1))
                let textLeft = inkLeft("open-files-1",
                                       fromX: Double(filesX0) + iconColumn + 4,
                                       toX: Double(filesX0 + filesWidth - 1))
                let rowLeft = textLeft.map { $0 - Double(DesignSystem.Size.fileIcon)
                    - Double(DesignSystem.Spacing.sm) }

                totalChecks += 1
                if let dashLeft, let rowLeft, let textLeft {
                    let delta = abs(dashLeft - rowLeft)
                    let pass = delta <= 1.0
                        && abs(dashLeft - expectedLeft) <= 1.5
                        && abs(rowLeft - expectedLeft) <= 1.5
                    if !pass { totalFailures += 1 }
                    print(String(
                        format: "[BASELINE] %@ files-e7-stability 虚线框左缘=%.1f 首行布局左缘=%.1f（文字墨迹 %.1f − 图标20 − 间距8）；差=%.1fpt（要求 0，容差 1.0 含字形左边距）；两态内容盒左缘=%.1f",
                        pass ? "PASS" : "FAIL", dashLeft, rowLeft, textLeft, delta, expectedLeft
                    ))
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL files-e7-stability 缺少 open-files-0/1 合成图或墨迹")
                }

                totalChecks += 1
                if let emptyInk, let oneInk {
                    let rowIconTop = Double(contentTopPt)
                        + Double(FileShelfLayout.rowHeight - DesignSystem.Size.fileIcon) / 2
                    let pass = abs(emptyInk.top - Double(contentTopPt)) <= 1.0
                        && abs(oneInk.top - rowIconTop) <= 2.5
                    if !pass { totalFailures += 1 }
                    print(String(
                        format: "[BASELINE] %@ files-top-anchor 虚线框上缘=%.1f（应 %.0f）首行图标上缘=%.1f（应 %.0f，20pt 图标居中于 32pt 行）；高度 124/124",
                        pass ? "PASS" : "FAIL", emptyInk.top, Double(contentTopPt),
                        oneInk.top, rowIconTop
                    ))
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL files-top-anchor 缺少 open-files-0/1 合成图")
                }
            }

            for (bundleID, enabled) in originalPlayersEnabled {
                PlayerRegistry.setEnabled(enabled, for: bundleID)
            }
            vm.reloadPlayerSettings()

            // 特写 1：闭合态顶部左右凹角（从合成图裁切，2x → 最近邻 3 倍 = 有效 6x）
            if let closedRep = captures["closed-idle"] {
                let closed = ScreenGeometry.closedSize(for: screen)
                let cx = (windowSize.width - closed.width) / 2
                let rect = CGRect(x: cx - 4, y: 0, width: closed.width + 8, height: 16)
                totalChecks += 1
                if writeCloseup(closedRep, rectPt: rect, scale: 2, upscale: 3,
                                folder: "corner-top", name: "corners.png") {
                    writeFolderMetrics("corner-top", [
                        "state": "corner-top",
                        "source": "closed-idle",
                        "effectiveScale": 6,
                        "cropPt": ["x": rect.minX, "y": rect.minY,
                                   "width": rect.width, "height": rect.height],
                        "note": "闭合态顶部两角；凹角肩内应 alpha=0（透出背景），弧外应为黑"
                    ])
                    print("[BASELINE] PASS corner-top corners.png")
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL corner-top 裁剪失败")
                }
            } else {
                totalChecks += 1
                totalFailures += 1
                print("[BASELINE] FAIL corner-top 缺少 closed-idle 合成图")
            }

            // 特写 2：展开首页左右直边 + 下沿抗锯齿带
            let homeEdgeState = "open-home"
            if let openRep = captures[homeEdgeState] {
                let home = PageMetrics.shapeSize(for: .home, shelfCount: 0)
                let ox = (windowSize.width - home.width) / 2
                let midY = home.height / 2
                let midX = ox + home.width / 2
                let leftRect = CGRect(x: ox - 4, y: midY - 6, width: 8, height: 12)
                let rightRect = CGRect(x: ox + home.width - 4, y: midY - 6, width: 8, height: 12)
                let bottomRect = CGRect(x: midX - 6, y: home.height - 4, width: 12, height: 8)
                var wrote = 0
                if writeCloseup(openRep, rectPt: leftRect, scale: 2, upscale: 3,
                                folder: "edges", name: "left.png") { wrote += 1 }
                if writeCloseup(openRep, rectPt: rightRect, scale: 2, upscale: 3,
                                folder: "edges", name: "right.png") { wrote += 1 }
                if writeCloseup(openRep, rectPt: bottomRect, scale: 2, upscale: 3,
                                folder: "edges", name: "bottom.png") { wrote += 1 }
                totalChecks += 1
                if wrote == 3 {
                    writeFolderMetrics("edges", [
                        "state": "edges",
                        "source": homeEdgeState,
                        "effectiveScale": 6,
                        "cropsPt": [
                            "left": ["x": leftRect.minX, "y": leftRect.minY,
                                     "width": leftRect.width, "height": leftRect.height],
                            "right": ["x": rightRect.minX, "y": rightRect.minY,
                                      "width": rightRect.width, "height": rightRect.height],
                            "bottom": ["x": bottomRect.minX, "y": bottomRect.minY,
                                       "width": bottomRect.width, "height": bottomRect.height]
                        ],
                        "note": "展开首页直边/下沿；2x 裁切后最近邻放大 3 倍"
                    ])
                    print("[BASELINE] PASS edges left/right/bottom.png")
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL edges 裁剪 \(wrote)/3")
                }
            } else {
                totalChecks += 1
                totalFailures += 1
                print("[BASELINE] FAIL edges 缺少 open-home 合成图")
            }

            // 顶部肩部对照（证据，不参与产品形状）：产品两态用同一条 NotchShape，只改切点偏移 t。
            // 另加一条**外凸圆弧**对照（RoundedRectangle 同一 t=19），用来验证判据本身有分辨力：
            // 内凹构造在 y=t/2 的首个不透明像素 = 0.914t；外凸圆弧 = 0.134t；方角 = 0。
            do {
                let folder = "corner-variants"
                let folderURL = dir.appendingPathComponent(folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                enum ShoulderKind: String {
                    case notchTangent
                    case convexArc
                }
                struct Variant {
                    let name: String
                    let topOffset: CGFloat
                    let bottomOffset: CGFloat
                    let width: CGFloat
                    let height: CGFloat
                    let kind: ShoulderKind
                    let note: String
                    /// y=t/2 行的首个不透明像素相对 x0 的偏移：内凹解析解 0.914t；外凸圆弧 0.134t。
                    var expectedOffset: Double {
                        switch kind {
                        case .notchTangent: return 0.914 * Double(topOffset)
                        case .convexArc: return Double(topOffset) * (1 - (3.0 / 4.0).squareRoot())
                        }
                    }
                }
                let variants = [
                    Variant(name: "closed-t6", topOffset: 6, bottomOffset: 14, width: 183, height: 32,
                            kind: .notchTangent,
                            note: "闭合态：切点偏移 t=6（参照值，绝对值未实测）"),
                    Variant(name: "open-t19-spec", topOffset: 19, bottomOffset: 24, width: 300, height: 148,
                            kind: .notchTangent,
                            note: "展开态规格：同一条构造、t=19（参照值，绝对值未实测）"),
                    Variant(name: "open-t0-retired", topOffset: 0, bottomOffset: 24, width: 300, height: 148,
                            kind: .notchTangent,
                            note: "作废规格：展开方角（耳部会被涂黑）"),
                    Variant(name: "convex-t19", topOffset: 19, bottomOffset: 24, width: 300, height: 148,
                            kind: .convexArc,
                            note: "外凸对照：把 19 喂进圆角通道（RoundedRectangle），首黑应 ≈2.5 而非 17.4")
                ]
                var reports: [[String: Any]] = []
                var discriminative = true
                var rendered: [String: NSBitmapImageRep] = [:]
                for variant in variants {
                    let canvas = ZStack(alignment: .topLeading) {
                        Color(red: 0.62, green: 0.64, blue: 0.67)
                        Group {
                            switch variant.kind {
                            case .notchTangent:
                                NotchShape(topTangentOffset: variant.topOffset,
                                           bottomTangentOffset: variant.bottomOffset)
                                    .fill(DesignSystem.Colors.surface)
                            case .convexArc:
                                RoundedRectangle(cornerRadius: variant.topOffset, style: .circular)
                                    .fill(DesignSystem.Colors.surface)
                            }
                        }
                        .frame(width: variant.width, height: variant.height)
                        .offset(x: 40, y: 40)
                    }
                    .frame(width: 360, height: 260)
                    let renderer = ImageRenderer(content: canvas)
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { continue }
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: folderURL.appendingPathComponent("\(variant.name).png"))
                    }
                    rendered[variant.name] = rep
                    func sampleRGBA(_ pt: CGPoint) -> [Int] {
                        guard let raw = rep.colorAt(x: Int((pt.x * 2).rounded()),
                                                    y: Int((pt.y * 2).rounded())),
                              let c = raw.usingColorSpace(.sRGB) else { return [-1, -1, -1, -1] }
                        return [Int((c.redComponent * 255).rounded()),
                                Int((c.greenComponent * 255).rounded()),
                                Int((c.blueComponent * 255).rounded()),
                                Int((c.alphaComponent * 255).rounded())]
                    }
                    let x0: CGFloat = 40
                    let y0: CGFloat = 40
                    let earLeft = sampleRGBA(CGPoint(x: x0 + 1, y: y0 + 1))
                    let earRight = sampleRGBA(CGPoint(x: x0 + variant.width - 1, y: y0 + 1))
                    let solidLeft = sampleRGBA(
                        CGPoint(x: x0 + variant.topOffset + 2, y: y0 + variant.topOffset + 2))
                    let scanY = y0 + (variant.topOffset > 0 ? variant.topOffset / 2 : 2)
                    var firstOffset: Double = -1
                    var scanX = Int(((x0 - 3) * 2).rounded())
                    let scanEnd = Int(((x0 + variant.topOffset + 10) * 2).rounded())
                    while scanX <= scanEnd {
                        if let raw = rep.colorAt(x: scanX, y: Int((scanY * 2).rounded())),
                           let c = raw.usingColorSpace(.sRGB) {
                            let rr = Double(c.redComponent)
                            let gg = Double(c.greenComponent)
                            let bb = Double(c.blueComponent)
                            let lum = 0.299 * rr + 0.587 * gg + 0.114 * bb
                            if lum < 0.18 {
                                firstOffset = Double(scanX) / 2 - Double(x0)
                                break
                            }
                        }
                        scanX += 1
                    }
                    let earIsBackground = earLeft[0] > 120
                    // 分辨力自检：产品两态与外凸对照的耳部都应是背景；
                    // 作废的方角必须把耳部涂黑；每条形状的首黑偏移都必须落在自己的解析解上。
                    if variant.name == "open-t0-retired" {
                        if earIsBackground { discriminative = false }
                    } else if !earIsBackground {
                        discriminative = false
                    }
                    if abs(firstOffset - variant.expectedOffset) > 1.0 { discriminative = false }
                    reports.append([
                        "name": variant.name,
                        "kind": variant.kind.rawValue,
                        "topOffset": variant.topOffset,
                        "width": variant.width,
                        "height": variant.height,
                        "note": variant.note,
                        "earLeftRGBA": earLeft,
                        "earRightRGBA": earRight,
                        "solidLeftRGBA": solidLeft,
                        "shoulderScanYPt": scanY,
                        "firstOpaqueOffsetPt": firstOffset,
                        "expectedOffsetPt": variant.expectedOffset
                    ])
                    print("[BASELINE] corner-variants \(variant.name) ear-left=\(earLeft) "
                          + "solid-left=\(solidLeft) 首黑 +\(String(format: "%.2f", firstOffset))pt"
                          + " 期望 +\(String(format: "%.2f", variant.expectedOffset))pt")
                }
                // 同族叠合：两态**数值不同**（闭合 t=6 / 展开 t=19），所以不能比像素重合，
                // 要比「按各自 t 归一化后的轮廓」。归一化坐标 v=y/t、u=(x−x0)/t：
                // 同一条 quad 构造在归一化后必须落在同一条曲线上；异族会分叉。
                var overlayReport: [String: Any] = ["written": false]
                var sameFamily = false
                var overlayHasPixels = false
                // 左边裁剪：闭合只占 6pt，展开占 19pt，两态给不同尺寸，各自看完整个肩部。
                let closedCrop = (w: 32, h: 20, ox: Int(40 * 2) - 8, oy: Int(40 * 2) - 4)   // 16×10pt
                let openCrop = (w: 56, h: 48, ox: Int(40 * 2) - 8, oy: Int(40 * 2) - 4)     // 28×24pt
                let closedTop = Double(ScreenGeometry.cornerRadiusInsets.closed.top)
                let openTop = Double(ScreenGeometry.cornerRadiusInsets.opened.top)
                if let cRep = rendered["closed-t6"], let oRep = rendered["open-t19-spec"] {
                    /// 归一化边界：在 v=y/t 处找左肩首个不透明黑像素，返回 u=(x−x0)/t
                    /// 以及**量化后**的实际 v（y 取整到设备像素后反算，供解析残差使用）。
                    func normalizedBoundary(
                        _ rep: NSBitmapImageRep, top: Double, v: Double
                    ) -> (u: Double, v: Double)? {
                        let yPt = 40 + v * top
                        let y = Int((yPt * 2).rounded())
                        let scanStart: CGFloat = 40 - 2
                        var px = Int((scanStart * 2).rounded())
                        let end = Int(((40 + top + 2) * 2).rounded())
                        while px <= end {
                            if let c = rep.colorAt(x: px, y: y)?.usingColorSpace(.sRGB) {
                                let rr: Double = Double(c.redComponent)
                                let gg: Double = Double(c.greenComponent)
                                let bb: Double = Double(c.blueComponent)
                                let lum: Double = 0.299 * rr + 0.587 * gg + 0.114 * bb
                                if c.alphaComponent > 0.7 && lum < 0.25 {
                                    // 一个设备像素高 0.5pt；首个变黑意味着该行已有约 3/4 被覆盖，
                                    // 对应的曲线高度约为行顶 +0.375pt（不是行顶 0，也不是行底 0.5）。
                                    let vActual = (Double(y) / 2 + 0.375 - 40) / top
                                    return ((Double(px) / 2 - 40) / top, vActual)
                                }
                            }
                            px += 1
                        }
                        return nil
                    }
                    let rows = 96
                    var maxResidual = 0.0
                    var profile: [[Double]] = []
                    var uC = [Double](repeating: -1, count: rows)
                    var uO = [Double](repeating: -1, count: rows)
                    for row in 0..<rows {
                        let v = (Double(row) + 0.5) / Double(rows)
                        guard let a = normalizedBoundary(cRep, top: closedTop, v: v),
                              let b = normalizedBoundary(oRep, top: openTop, v: v) else { continue }
                        uC[row] = a.u; uO[row] = b.u
                        // 判据：两态各自对解析解 u(v)=2√v−v 的残差。
                        // 不能直接比 u(闭合)−u(展开)：v→0 处 du/dv=1/√v−1→∞，
                        // 闭合 t=6 只有 6pt 覆盖整个肩部，1px 的 y 量化会被放大成 ≈0.08u，
                        // 展开 t=19 只有 ≈0.03u——差值是采样栅格，不是形状。
                        let analyticC = 2 * a.v.squareRoot() - a.v
                        let analyticO = 2 * b.v.squareRoot() - b.v
                        maxResidual = max(maxResidual, abs(a.u - analyticC), abs(b.u - analyticO))
                        profile.append([v, a.u, b.u, abs(a.u - b.u)])
                    }
                    // 归一化轮廓图：红=闭合，青=展开，两者落在同一像素即白（同族）。
                    let plotW = rows, plotH = rows
                    var plot = [UInt8](repeating: 0, count: plotW * plotH * 4)
                    for i in 0..<(plotW * plotH) {
                        plot[i * 4] = 24; plot[i * 4 + 1] = 24; plot[i * 4 + 2] = 24; plot[i * 4 + 3] = 255
                    }
                    for row in 0..<rows {
                        let prow = rows - 1 - row
                        for (u, isClosed) in [(uC[row], true), (uO[row], false)] where u >= 0 {
                            let col = min(max(Int((u * Double(plotW)).rounded()), 0), plotW - 1)
                            let o = (prow * plotW + col) * 4
                            let wasClosed = plot[o] == 220
                            let wasOpen = plot[o] == 60 && plot[o + 2] == 220
                            if wasClosed || wasOpen {
                                plot[o] = 255; plot[o + 1] = 255; plot[o + 2] = 255
                            } else if isClosed {
                                plot[o] = 220; plot[o + 1] = 60; plot[o + 2] = 60
                            } else {
                                plot[o] = 60; plot[o + 1] = 200; plot[o + 2] = 220
                            }
                        }
                    }
                    let plotZoom = 4
                    var up = [UInt8](repeating: 0, count: plotW * plotZoom * plotH * plotZoom * 4)
                    let upW = plotW * plotZoom
                    for ur in 0..<(plotH * plotZoom) {
                        let sr = ur / plotZoom
                        for uc in 0..<upW {
                            let s = (sr * plotW + uc / plotZoom) * 4
                            let d = (ur * upW + uc) * 4
                            up[d] = plot[s]; up[d + 1] = plot[s + 1]
                            up[d + 2] = plot[s + 2]; up[d + 3] = plot[s + 3]
                        }
                    }
                    /// 逐像素裁剪（每态自己的 t，不归一化），便于直接看形状。
                    func crop(_ rep: NSBitmapImageRep, _ box: (w: Int, h: Int, ox: Int, oy: Int),
                              _ name: String) -> Bool {
                        var buf = [UInt8](repeating: 0, count: box.w * box.h * 4)
                        for row in 0..<box.h {
                            for col in 0..<box.w {
                                guard let c = rep.colorAt(x: box.ox + col, y: box.oy + row)?
                                    .usingColorSpace(.sRGB) else { continue }
                                let a = Double(c.alphaComponent)
                                let dst = (row * box.w + col) * 4
                                buf[dst] = rgbaByte(Double(c.redComponent) * a)
                                buf[dst + 1] = rgbaByte(Double(c.greenComponent) * a)
                                buf[dst + 2] = rgbaByte(Double(c.blueComponent) * a)
                                buf[dst + 3] = rgbaByte(a)
                            }
                        }
                        return writeRGBAImage(buf, width: box.w, height: box.h,
                                              to: folderURL.appendingPathComponent(name))
                    }
                    let wroteClosed = crop(cRep, closedCrop, "shoulder-closed.png")
                    let wroteOpen = crop(oRep, openCrop, "shoulder-open-t19.png")
                    let wrotePlot = writeRGBAImage(up, width: upW, height: upW,
                                                   to: folderURL.appendingPathComponent("shoulder-overlay-normalized.png"))
                    // 容差按归一化单位给 0.12：闭合 t=6 时 1 个设备像素就是 0.083u，
                    // 再严就测到采样精度而不是形状本身了。
                    sameFamily = maxResidual <= 0.12 && profile.count >= rows / 2
                    let white = stride(from: 0, to: plot.count, by: 4).reduce(0) {
                        $0 + (plot[$1] == 255 ? 1 : 0)
                    }
                    overlayHasPixels = wrotePlot && white > 0
                    overlayReport = [
                        "written": wrotePlot,
                        "file": wrotePlot ? "shoulder-overlay-normalized.png" : NSNull(),
                        "closedFile": wroteClosed ? "shoulder-closed.png" : NSNull(),
                        "openFile": wroteOpen ? "shoulder-open-t19.png" : NSNull(),
                        "closedTopPt": closedTop,
                        "openTopPt": openTop,
                        "normalized": "u=(x−x0)/t, v=(y−y0)/t；红=闭合 青=展开 白=重合；判定用「各自对 u(v)=2√v−v 的残差」，不用红青逐行差",
                        "whitePixelCount": white,
                        "maxNormalizedResidual": maxResidual,
                        "profileRows": profile
                    ]
                }
                writeFolderMetrics(folder, [
                    "analytic": "顶部肩为二次曲线：u(v)=2√v−v（v=y/t），y=t/2 处 u=0.914；t=0 退化为直边；外凸圆弧在 y=t/2 处 u=0.134",
                    "variants": reports,
                    "overlay": overlayReport
                ])
                totalChecks += 1
                if discriminative {
                    print("[BASELINE] PASS corner-variants 探针能区分内凹肩 / 方角 / 外凸圆弧")
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL corner-variants 探针失去分辨力")
                }
                totalChecks += 1
                if sameFamily {
                    let residual = (overlayReport["maxNormalizedResidual"] as? Double) ?? -1
                    print(String(format: "[BASELINE] PASS shoulder-overlay 两态都贴合解析轮廓（最大残差 %.3fu）", residual))
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL shoulder-overlay 闭合与展开肩部不同族")
                }
                // 图形证据自身也要能真红：空的 PNG 曾经被当成「叠合通过」的证据。
                totalChecks += 1
                if overlayHasPixels {
                    let white = (overlayReport["whitePixelCount"] as? Int) ?? 0
                    let rows = (overlayReport["profileRows"] as? [[Double]])?.count ?? 0
                    print("[BASELINE] PASS shoulder-overlay-evidence 归一化轮廓图含 \(white) 个重合白像素（\(rows) 行采样）")
                } else {
                    totalFailures += 1
                    print("[BASELINE] FAIL shoulder-overlay-evidence 叠合图未写出、全透明或两态无重合")
                }
            }

            let summary: [String: Any] = [
                "generatedAt": ISO8601DateFormatter().string(from: Date()),
                "capture": "own-window-composite @2x",
                "states": index,
                "checks": totalChecks,
                "failures": totalFailures
            ]
            if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: dir.appendingPathComponent("index.json"))
            }
            print("[BASELINE] \(totalFailures == 0 ? "PASS" : "FAIL") \(totalChecks) checks, \(totalFailures) failed -> \(dir.path)")
            exit(totalFailures == 0 ? 0 : 2)
        }
    }

    // MARK: - 窗口截图演示：自己窗口的合成图 + 纯视图层对照

    /// `--capture-demo=<dir>`：不依赖屏幕录制权限（TCC 对 `screencapture` 是拒绝的），
    /// 直接让 app 抓**自己窗口**的窗口服务器合成图，再补一张纯视图层快照做对照。
    ///
    /// 三组状态各抓一次：指针在面板外（闭合）/ 指针在面板内（已展开）/ 指针移出后（闭合）。
    /// 视图层快照与窗口合成图的差异，就是「系统画的」与「我们画的」的分界。
    @MainActor
    private func runCaptureDemo(outputDirectory: String) {
        guard let controller else {
            print("[CAPTURE] FAIL: controller not created")
            exit(1)
        }
        // 程序化驱动 hover，避免依赖辅助功能权限去投递鼠标事件；
        // 走的是和真实 hover 完全相同的入口 `handlePointer(inside:)`。
        controller.pointerTrackingEnabled = false
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panel = controller.windowForTesting

        func write(_ name: String, _ rep: NSBitmapImageRep, note: String) {
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("[CAPTURE] FAIL \(name) png encode")
                return
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("[CAPTURE] wrote \(name).png px=\(rep.pixelsWide)x\(rep.pixelsHigh)"
                  + " points=\(Int(panel.frame.width))x\(Int(panel.frame.height))"
                  + " scale=\(panel.backingScaleFactor) \(note)")
        }

        /// 窗口服务器合成图：包含系统为窗口画的东西（边框/样式），是「看得见的现象」。
        /// `framed == true` 时不传 `.boundsIgnoreFraming`，窗口框与阴影一并入图——
        /// 白边如果画在「框」上，只有这一张能看到。
        func captureWindow(_ name: String, framed: Bool = false) {
            let options: CGWindowImageOption = framed
                ? [.bestResolution]
                : [.boundsIgnoreFraming, .bestResolution]
            guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(panel.windowNumber), options
            ) else {
                print("[CAPTURE] FAIL \(name): CGWindowListCreateImage nil")
                return
            }
            write(name, NSBitmapImageRep(cgImage: image),
                  note: framed ? "window-composited+framed" : "window-composited")
            // 尺寸对账：点 × backingScaleFactor 必须等于像素，否则说明这张图被裁过，
            // 边界判定无效。只有 `.boundsIgnoreFraming` 那一张应当 match=true。
            let scale = panel.backingScaleFactor
            let expected = (
                Int((panel.frame.width * scale).rounded()),
                Int((panel.frame.height * scale).rounded())
            )
            print("[CAPTURE] bounds-check \(name) imagePx=\(image.width)x\(image.height)"
                  + " windowPt=\(Int(panel.frame.width))x\(Int(panel.frame.height))"
                  + " scale=\(scale) expectedPx=\(expected.0)x\(expected.1)"
                  + " match=\(image.width == expected.0 && image.height == expected.1)")
        }

        /// 纯视图层快照：只有 AppKit/SwiftUI 自己画的内容，系统边框不会出现。
        func captureView(_ name: String) {
            guard let view = panel.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("[CAPTURE] FAIL \(name): view snapshot unavailable")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            write(name, rep, note: "view-only")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            captureWindow("01-closed-pointer-outside")
            captureWindow("01b-closed-framed", framed: true)
            captureView("01v-closed-view-only")

            // 真把光标挪进面板：程序化 `handlePointer` 只覆盖 App 自己的状态，
            // 系统是否按「光标悬停在窗口上」画装饰，只有真光标在窗口里才成立。
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let origin = CGPoint(
                x: panel.frame.midX,
                y: screenHeight - (panel.frame.maxY - 16)
            )
            CGWarpMouseCursorPosition(origin)
            controller.handlePointer(inside: true)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            captureWindow("02-open-pointer-inside")
            captureWindow("02b-open-framed", framed: true)
            captureView("02v-open-view-only")

            // 焦点：能不能成为 key，是「焦点环」假设成立与否的前提。
            print("[FOCUS] canBecomeKey=\(panel.canBecomeKey) canBecomeMain=\(panel.canBecomeMain)"
                  + " becomesKeyOnlyIfNeeded=\(panel.becomesKeyOnlyIfNeeded)"
                  + " isKey=\(panel.isKeyWindow) isMain=\(panel.isMainWindow)"
                  + " styleMask=\(panel.styleMask.rawValue)")
            print("[WINDOW] hasShadow=\(panel.hasShadow) isOpaque=\(panel.isOpaque)"
                  + " backgroundColor=\(String(describing: panel.backgroundColor))"
                  + " titlebarAppearsTransparent=\(panel.titlebarAppearsTransparent)"
                  + " level=\(panel.level.rawValue) alpha=\(panel.alphaValue)"
                  + " ignoresMouseEvents=\(panel.ignoresMouseEvents)")
            panel.makeKey()
            print("[FOCUS] after makeKey() isKey=\(panel.isKeyWindow) isMain=\(panel.isMainWindow)")

            controller.handlePointer(inside: false)
            CGWarpMouseCursorPosition(CGPoint(x: panel.frame.midX, y: screenHeight - 400))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            captureWindow("03-closed-pointer-outside-again")
            print("[CAPTURE] done plainStyle=\(NotchPanel.usesPlainStyle) window=\(panel.windowNumber)")
            exit(0)
        }
    }

    // MARK: - 窗口坐标探针：查清 WindowServer 合成 bounds 与 frame 的差异

    /// `--window-probe`：在窗口创建后的 0/100/500ms/1s/3s 五个时间点采样，回答
    /// 「为什么 window.frame 是 316×148，CGWindowList 却报 286×134」。
    ///
    /// 每个时间点、每个窗口记录五项：`window.frame`、`contentLayoutRect`、
    /// CGWindowList bounds、`backingScaleFactor`、`CGDisplayMode`。
    /// 对照窗口是纯 `.borderless`、`level = .normal`（不设 hudWindow / utilityWindow），
    /// 用来判断差异是否由面板样式或窗口层级引入。
    @MainActor
    private func runWindowProbe(screen: NSScreen) {
        guard let controller else {
            print("[WPROBE] FAIL: controller not created")
            exit(1)
        }
        controller.pointerTrackingEnabled = false
        let panel = controller.windowForTesting

        let control = ProbeWindow(
            contentRect: ScreenGeometry.windowFrame(for: screen),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        control.isOpaque = true
        control.backgroundColor = .black
        control.hasShadow = false
        control.isMovable = false
        control.isReleasedWhenClosed = false
        control.level = .normal
        control.ignoresMouseEvents = true
        control.setFrame(ScreenGeometry.windowFrame(for: screen), display: true)
        control.orderFrontRegardless()

        let start = ProcessInfo.processInfo.systemUptime

        print("[WPROBE] --- 环境 ---")
        print("[WPROBE] screens=\(NSScreen.screens.count) main=\(NSScreen.main?.localizedName ?? "-")")
        for (index, s) in NSScreen.screens.enumerated() {
            print("[WPROBE] screen[\(index)] name=\(s.localizedName) frame=\(rectString(s.frame))"
                  + " visible=\(rectString(s.visibleFrame)) backing=\(s.backingScaleFactor)"
                  + " safeTop=\(s.safeAreaInsets.top)")
            print("[WPROBE] screen[\(index)] \(displayLine(for: s))")
        }
        print("[WPROBE] panel   windowNumber=\(panel.windowNumber) level=\(panel.level.rawValue)"
              + " styleMask=\(panel.styleMask.rawValue) colBehavior=\(panel.collectionBehavior.rawValue)")
        print("[WPROBE] control windowNumber=\(control.windowNumber) level=\(control.level.rawValue)"
              + " styleMask=\(control.styleMask.rawValue)")

        // 参考窗口：位置/尺寸都已知，用来反解 AppKit 坐标 → CGWindowList 坐标的变换。
        // 只有四个参考点都在，才能判断是「整体等比缩小（合成空间比显示屏大）」
        // 还是「只剩下内容被缩放（框架位置不变）」。
        let bounds = screen.frame
        let references: [(name: String, window: NSWindow)] = [
            ("ref-bl", referenceWindow(NSRect(x: bounds.minX, y: bounds.minY, width: 100, height: 100))),
            ("ref-tr", referenceWindow(NSRect(x: bounds.maxX - 100, y: bounds.maxY - 100,
                                              width: 100, height: 100))),
            ("ref-br", referenceWindow(NSRect(x: bounds.maxX - 100, y: bounds.minY,
                                              width: 100, height: 100))),
            ("ref-full", referenceWindow(bounds)),
            ("ref-center", referenceWindow(NSRect(x: bounds.midX - 50, y: bounds.midY - 50,
                                                  width: 100, height: 100)))
        ]

        Task { @MainActor in
            let marks: [(String, Double)] = [
                ("0ms", 0), ("100ms", 0.1), ("500ms", 0.5), ("1s", 1.0), ("3s", 3.0)
            ]
            for (label, target) in marks {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if target > elapsed {
                    try? await Task.sleep(nanoseconds: UInt64((target - elapsed) * 1_000_000_000))
                }
                let now = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                print("[WPROBE] t=\(label) (+\(now)ms) panel   \(sampleLine(for: panel, screen: screen))")
                print("[WPROBE] t=\(label) (+\(now)ms) control \(sampleLine(for: control, screen: screen))")
            }
            for reference in references {
                let cg = cgWindowBounds(for: reference.window).map(rectString) ?? "nil"
                print("[WPROBE] \(reference.name) frame=\(rectString(reference.window.frame)) cg=\(cg)")
            }
            // 用参考窗口反解变换：等比缩放多少、四周留了多少边。
            let cgByRef = Dictionary(uniqueKeysWithValues: references.compactMap { reference in
                cgWindowBounds(for: reference.window).map { (reference.name, $0) }
            })
            if let bl = cgByRef["ref-bl"], let tr = cgByRef["ref-tr"], let full = cgByRef["ref-full"] {
                print(String(
                    format: "[WPROBE] 变换反解 scaleX=%.4f scaleY=%.4f leftGap=%.1f topGap=%.1f"
                        + " desktopInCG=%.1fx%.1f 反推空间=%.1fx%.1f",
                    tr.width / 100, tr.height / 100, bl.minX, full.minY,
                    full.width, full.height,
                    full.width + 2 * bl.minX, full.height + 2 * full.minY
                ))
            }
            concludeWindowProbe(
                panel: panel,
                control: control,
                screen: screen,
                desktopBounds: cgByRef["ref-full"]
            )
        }
    }

    /// 参考窗口：纯 .borderless、黑色背景、无阴影，位置尺寸由调用方给。
    ///
    /// 用 `ProbeWindow` 是为了绕开 AppKit 的 `constrainFrameRect`：默认实现会把 .normal 级
    /// 窗口从菜单栏下面推开（实测被下移 33pt，正好是菜单栏高度），那样就没法和贴着屏幕顶的
    /// 面板比较了。
    @MainActor
    private func referenceWindow(_ frame: NSRect) -> NSWindow {
        let window = ProbeWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    /// 用两个 100×100 的角落参考窗口标定 CGWindowList 的全局空间。
    ///
    /// 之所以要标定：本机 `CGWindowListCopyWindowInfo` 报的 bounds 不在 NSScreen 的 point 空间里
    /// （实测整块桌面被缩到 1324×862 并居中，见 `--window-probe`）。标定之后
    /// 就能把 `window.frame` 换算到同一空间做严格比较，而不是笼统地说「等比缩放就算过」。
    @MainActor
    private func cgSpaceMapper(for screen: NSScreen) async -> CGSpaceMapper? {
        let frame = screen.frame
        let low = referenceWindow(NSRect(x: frame.minX, y: frame.minY, width: 100, height: 100))
        let high = referenceWindow(NSRect(x: frame.maxX - 100, y: frame.maxY - 100,
                                          width: 100, height: 100))
        try? await Task.sleep(nanoseconds: 180_000_000)
        let lowBounds = cgWindowBounds(for: low)
        let highBounds = cgWindowBounds(for: high)
        low.orderOut(nil)
        high.orderOut(nil)
        guard let lowBounds, let highBounds else { return nil }
        return CGSpaceMapper(
            screen: frame,
            lowFrame: low.frame,
            lowBounds: lowBounds,
            highFrame: high.frame,
            highBounds: highBounds
        )
    }

    /// 一个时间点的五项采样。
    @MainActor
    private func sampleLine(for window: NSWindow, screen: NSScreen) -> String {
        let frame = window.frame
        var parts: [String] = []
        parts.append("frame=\(rectString(frame))")
        parts.append("contentLayout=\(rectString(window.contentLayoutRect))")
        parts.append("content=\(rectString(window.contentView?.frame ?? .zero))")
        if let cg = cgWindowBounds(for: window) {
            parts.append("cg=\(rectString(cg))")
            if frame.width > 0, frame.height > 0 {
                parts.append(String(
                    format: "cg/frame=%.4f/%.4f",
                    cg.width / frame.width, cg.height / frame.height
                ))
            }
        } else {
            parts.append("cg=nil")
        }
        parts.append("backing=\(window.backingScaleFactor)")
        if let mode = displayMode(for: screen) {
            parts.append("mode=\(Int(mode.width))x\(Int(mode.height))"
                         + " px=\(mode.pixelWidth)x\(mode.pixelHeight)"
                         + " refresh=\(Int(mode.refreshRate.rounded()))")
        }
        parts.append("screen.frame=\(rectString(screen.frame))")
        return parts.joined(separator: " ")
    }

    /// 采样结束后把「frame → CG bounds」和「整块桌面 → CG bounds」的缩放逐项比对。
    @MainActor
    private func concludeWindowProbe(panel: NSWindow, control: NSWindow,
                                     screen: NSScreen, desktopBounds: CGRect?) {
        let frame = panel.frame
        guard let cg = cgWindowBounds(for: panel) else {
            print("[WPROBE] FAIL: no CGWindowList bounds for panel")
            exit(1)
        }
        let controlBounds = cgWindowBounds(for: control)
        let windowScale = cg.width / frame.width
        let windowScaleY = cg.height / frame.height
        let displayID = displayID(of: screen)
        let cgScreen = CGDisplayBounds(displayID)
        let desktop = desktopBounds ?? cgScreen
        let desktopScale = desktop.width / screen.frame.width
        let desktopScaleY = desktop.height / screen.frame.height
        let leftInset = desktop.minX - screen.frame.minX * desktopScale
        let topInset = desktop.minY

        print("[WPROBE] --- 结论 ---")
        print(String(format: "[WPROBE] frame=%@ cg=%@ windowScale=%.4f/%.4f",
                     rectString(frame), rectString(cg), windowScale, windowScaleY))
        print(String(format: "[WPROBE] CGDisplayBounds=%@ NSScreen.frame=%@（两者相等，说明 point 空间本身没问题）",
                     rectString(cgScreen), rectString(screen.frame)))
        print(String(format: "[WPROBE] 整屏窗口 桌面在 CG 空间里=%@ scale=%.4f/%.4f 左/上内边距=%.1f/%.1f"
                        + " 反推合成空间=%.1fx%.1f",
                     rectString(desktop), desktopScale, desktopScaleY, leftInset, topInset,
                     desktop.width + 2 * leftInset, desktop.height + 2 * topInset))
        if let controlBounds {
            print(String(format: "[WPROBE] control frame=%@ cg=%@ scale=%.4f",
                         rectString(control.frame), rectString(controlBounds),
                         controlBounds.width / control.frame.width))
        }

        // 判定：偏差到底出在哪两个量上。
        let mapped = CGRect(
            x: leftInset + (frame.minX - screen.frame.minX) * desktopScale,
            y: topInset + (screen.frame.maxY - frame.maxY) * desktopScaleY,
            width: frame.width * desktopScale,
            height: frame.height * desktopScaleY
        )
        let residual = max(
            abs(cg.minX - mapped.minX), abs(cg.minY - mapped.minY),
            abs(cg.width - mapped.width), abs(cg.height - mapped.height)
        )
        if residual <= 0.1 {
            print("[WPROBE] VERDICT: 合成 bounds 等于 frame（缩放=1，残差 \(String(format: "%.2f", residual))pt）")
        } else if residual <= 2 {
            print(String(format: "[WPROBE] VERDICT: bounds == frame × 桌面变换，残差 %.2fpt（CG bounds 逐边取整）"
                            + " —— 对不上的两个量是【NSScreen.frame / CGDisplayBounds 的 point 空间】"
                            + "与【CGWindowList 的全局空间】；窗口自身尺寸与位置没有偏差",
                         residual))
            print(String(format: "[WPROBE]         期望值 %@ / 实际 %@（0.905 是那个空间差，不是窗口尺寸差）",
                         rectString(mapped), rectString(cg)))
        } else {
            print(String(format: "[WPROBE] VERDICT: 残差 %.2fpt > 2pt，偏差不是坐标系整体变换造成的，需要继续查",
                         residual))
        }
        if let controlBounds, controlBounds == cg {
            print("[WPROBE] VERDICT: 对照窗口（无 hud/utility 样式、level=.normal）合成 rect 完全相同"
                  + " —— 与面板样式、窗口层级无关")
        } else if let controlBounds {
            print("[WPROBE] VERDICT: 对照窗口合成 rect 不同（panel=\(cg) control=\(controlBounds)）"
                  + " —— 与面板样式相关")
        }
        print("[WPROBE] done")
        exit(0)
    }

    private func rectString(_ rect: CGRect) -> String {
        String(format: "%.1fx%.1f@(%.1f,%.1f)", rect.width, rect.height, rect.minX, rect.minY)
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    private func displayMode(for screen: NSScreen) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(displayID(of: screen))
    }

    private func displayLine(for screen: NSScreen) -> String {
        let id = displayID(of: screen)
        let bounds = CGDisplayBounds(id)
        let pixels = "\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
        let mode = displayMode(for: screen)
        let modeText = mode.map {
            "\(Int($0.width))x\(Int($0.height)) px=\($0.pixelWidth)x\($0.pixelHeight)"
                + String(format: " refresh=%.1f", $0.refreshRate)
        } ?? "nil"
        return "display=\(id) cgBounds=\(rectString(bounds)) cgPixels=\(pixels) mode=\(modeText)"
    }

    private func cgWindowBounds(for window: NSWindow) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let number = window.windowNumber
        for info in list {
            guard let n = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, n == number,
                  let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            return bounds
        }
        return nil
    }

    // MARK: - 肩部对称性探针：闭合形状左右两端各放大 4 倍

    /// `--shoulder-probe`：闭合形状左右两个肩部是否仍互为镜像。
    ///
    /// 做法：@4x 离屏渲染闭合态（含闭合加宽 28pt 的播放态），
    /// 1. 逐行量左右两侧的「内缩量」，和 NotchShape 的二次曲线解析值比对；
    /// 2. 左右逐行镜像差值必须 ≤ 1 设备像素；
    /// 3. 把左右各 40pt 宽的区域裁出来落盘成两张放大图，供肉眼确认。
    @MainActor
    private func runShoulderProbe(screen: NSScreen) {
        let scale: CGFloat = 4
        let closed = ScreenGeometry.closedSize(for: screen)
        let extra = DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm
        let outputDirectory: String? = {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }()
        let dir = outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var allPass = true
        for (label, widen) in [("closed", false), ("closed+badge", true)] {
            guard let rep = renderCanvas(
                open: false,
                fixture: widen ? .playing : .none,
                screen: screen,
                withMarker: false,
                scale: scale
            ) else {
                print("[SHOULDER] FAIL: render \(label)")
                exit(1)
            }
            let probe = ShoulderProbe(
                rep: rep,
                shapeSize: CGSize(width: closed.width + (widen ? extra : 0), height: closed.height),
                offset: widen ? extra / 2 : 0,
                scale: scale,
                topRadius: ScreenGeometry.cornerRadiusInsets.closed.top,
                bottomRadius: ScreenGeometry.cornerRadiusInsets.closed.bottom
            )
            let result = probe.measure()
            // 判据一：左右内缩量的「逐行差值」必须几乎恒定 —— 差值恒定说明两条曲线是
            //         同一条曲线，只是整块有 1px 次像素偏移；差值随行变化才是真的不对称。
            // 判据二：两侧都必须落在 NotchShape 的二次曲线解析解上（±2px 抗锯齿容差）。
            let pass = result.mirrorSpread <= 0.5 && result.maxMirrorDiff <= 1.25
                && result.maxCurveError <= 2.0
            allPass = allPass && pass
            print("[SHOULDER] \(label) shape=\(Int(probe.shapeSize.width))x\(Int(probe.shapeSize.height))"
                  + " offset=\(probe.offset) rows=\(result.rows)"
                  + String(format: " maxMirrorDiff=%.2fpx spread=%.2fpx maxCurveError=%.2fpx %@",
                           result.maxMirrorDiff, result.mirrorSpread, result.maxCurveError,
                           pass ? "PASS" : "FAIL"))
            print("[SHOULDER] \(label) 每行内缩(pt) y:左/右 = " + result.profile)
            print("[SHOULDER] \(label) 直边段边缘亮度 " + probe.edgeProfile(yPt: 20))

            if widen, let dir {
                let left = probe.cropRect(side: .left, width: 40)
                let right = probe.cropRect(side: .right, width: 40)
                for (name, rect) in [("closed-shoulder-left-4x.png", left),
                                     ("closed-shoulder-right-4x.png", right)] {
                    if let cg = rep.cgImage?.cropping(to: rect) {
                        let out = NSBitmapImageRep(cgImage: cg)
                        if let png = out.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent(name))
                            print("[SHOULDER] wrote \(name) \(Int(rect.width))x\(Int(rect.height))px")
                        }
                    }
                }
            }
        }

        print("[SHOULDER] \(allPass ? "PASS" : "FAIL") both shoulders are mirror-symmetric")
        exit(allPass ? 0 : 2)
    }

    // MARK: - 阴影像素探针：方向性阴影的量化验收

    /// 在离屏图上逐像素量三件事：
    /// 1. 面板左右两侧 y∈[0,8]pt 是否还有竖向暗带（要求 ≤ 背景容差）；
    /// 2. 顶边 y=0 与 y<0 区域是否有水平暗线；
    /// 3. 底部阴影的最大扩散距离与峰值不透明度。
    ///
    /// 坐标换算：画布 offset (40,40)pt、scale 2 → 窗口左上角在设备像素 (80,80)。
    @MainActor
    private func runShadowProbe(screen: NSScreen, outputDirectory: String?) {
        // 背景是固定色 rgb(0.62,0.64,0.67)，抗锯齿之外的纯背景像素之间差值应为 0；
        // 容差取 3/255，允许 PNG 色彩空间变换带来的 ≤1 灰阶抖动。
        let tolerance = 3.0
        var allPass = true
        var report: [String] = []
        let closedSize = ScreenGeometry.closedSize(for: screen)

        if let outputDirectory {
            let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for open in [false, true] {
                if let rep = renderCanvas(open: open, screen: screen, withMarker: false),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(open ? "open-clean.png" : "closed-clean.png"))
                }
            }
        }

        for open in [false, true] {
            let label = open ? "open" : "closed"
            guard let rep = renderCanvas(open: open, screen: screen, withMarker: false) else {
                print("[SHADOW] FAIL: render \(label)")
                exit(1)
            }
            let probe = ShadowProbe(
                rep: rep,
                open: open,
                panelSize: open ? PageMetrics.shapeSize(for: .home) : closedSize
            )

            let side = probe.sideBandWorst()
            let top = probe.topEdgeDarkness()
            let bottom = probe.bottomSpread()

            let sideOK = side.maxDark <= tolerance
            let topOK = top.atTopRow <= tolerance && top.above <= tolerance
            // 闭合态必须完全不投影；展开态底部阴影必须真实存在（否则说明阴影被一并关掉了）。
            let bottomOK = open ? bottom.peakAlpha > 0.02 : bottom.peakAlpha <= 0.01
            allPass = allPass && sideOK && topOK && bottomOK

            report.append(String(format: "[SHADOW] %@ side y=[0,8]pt maxDark=%.1f/255 at x=%.1fpt %@",
                                 label, side.maxDark, side.worstX, sideOK ? "PASS" : "FAIL"))
            report.append("[SHADOW] \(label) side columns x:dark = " + side.columns)
            report.append(String(format: "[SHADOW] %@ top y=0 maxDark=%.1f/255  y<0 maxDark=%.1f/255 %@",
                                 label, top.atTopRow, top.above, topOK ? "PASS" : "FAIL"))
            report.append(String(format: "[SHADOW] %@ bottom spread=%.1fpt peakDark=%.1f/255 peakAlpha=%.3f at +%.1fpt %@",
                                 label, bottom.spread, bottom.peakDark, bottom.peakAlpha, bottom.peakOffset,
                                 bottomOK ? "PASS" : "FAIL"))
        }

        report.forEach { print($0) }
        print("[SHADOW] \(allPass ? "PASS" : "FAIL") directional shadow (tolerance=\(tolerance)/255)")
        exit(allPass ? 0 : 2)
    }


    // MARK: - 端到端：真实指针移动

    private func runEndToEndHoverTest() {
        guard let controller else {
            print("[E2E] FAIL: controller not created")
            exit(1)
        }

        Task { @MainActor in
            let original = NSEvent.mouseLocation
            let closedRect = ScreenGeometry.closedRect(for: controller.metricsForTesting)
            let target = NSPoint(x: closedRect.midX, y: closedRect.midY)
            let away = NSPoint(x: target.x, y: max(target.y - 420, 120))

            print("[E2E] cursor original=\(original) target=\(target)")
            postMouseMove(to: target)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let opened = controller.viewModelForTesting.isOpen
            print("[E2E] after hover: open=\(opened) ignoresMouseEvents=\(controller.windowForTesting.ignoresMouseEvents)")
            NSLog("[E2E] after hover: open=%d", opened ? 1 : 0)

            postMouseMove(to: away)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let closed = !controller.viewModelForTesting.isOpen
            print("[E2E] after leave: closed=\(closed) ignoresMouseEvents=\(controller.windowForTesting.ignoresMouseEvents)")
            NSLog("[E2E] after leave: closed=%d", closed ? 1 : 0)

            postMouseMove(to: original)
            print(opened && closed ? "[E2E] PASS real pointer hover works" : "[E2E] FAIL real pointer hover not delivered")
            exit(opened && closed ? 0 : 1)
        }
    }

    /// AppKit 屏幕坐标（原点左下）转 CG 全局坐标（原点左上）。
    private func cgPoint(fromAppKit point: NSPoint) -> CGPoint {
        let mainFrame = NSScreen.screens.first?.frame ?? .zero
        return CGPoint(x: point.x - mainFrame.minX, y: mainFrame.maxY - point.y)
    }

    private func postMouseMove(to point: NSPoint) {
        let cg = cgPoint(fromAppKit: point)
        CGWarpMouseCursorPosition(cg)
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: cg,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - 裸像素写图

/// 把 RGBA8 缓冲区写成 PNG。
///
/// 不用 `NSBitmapImageRep(bitmapDataPlanes:) + setColor(_:atX:y:)`：本机这条路径是 no-op
/// （写进去读回来全是 0），曾导致 `shoulder-overlay.png` 里 0 个不透明像素。
/// 这里直接由缓冲区建 `CGImage`，行序为自上而下。
@discardableResult
func writeRGBAImage(_ pixels: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
    guard width > 0, height > 0, pixels.count == width * height * 4,
          let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width, height: height,
              bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false,
              intent: .defaultIntent
          ),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: url)) != nil
}

/// 预乘到 0…255 的分量。
func rgbaByte(_ v: Double) -> UInt8 {
    UInt8((min(max(v, 0), 1) * 255).rounded())
}

// MARK: - 阴影像素探针

/// 在 `--shadow-probe` 渲染出的**不带红线**的图上做像素扫描。
///
/// 坐标体系：图像是设备像素（@2x），窗口左上角固定在 (80,80)，窗口 656×210pt。
/// 「暗度」定义为背景亮度减去该像素亮度（0…255）；阴影是纯黑叠加，
/// 故 `peakAlpha ≈ 暗度 / 背景亮度` 可直接当作该点的有效不透明度。
struct ShadowProbe {
    let rep: NSBitmapImageRep
    let open: Bool
    let panelSize: CGSize

    private let windowX = 80
    private let windowY = 80
    private let scale = 2

    init(rep: NSBitmapImageRep, open: Bool, panelSize: CGSize) {
        self.rep = rep
        self.open = open
        self.panelSize = panelSize
    }

    private var imageWidth: Int { rep.pixelsWide }
    private var imageHeight: Int { rep.pixelsHigh }
    private var windowWidth: Int { Int(ScreenGeometry.windowSize.width) * scale }
    private var windowHeight: Int { Int(ScreenGeometry.windowSize.height) * scale }
    private var panelWidth: Int { Int(panelSize.width * CGFloat(scale)) }
    private var panelHeight: Int { Int(panelSize.height * CGFloat(scale)) }
    private var panelX0: Int { windowX + (windowWidth - panelWidth) / 2 }
    private var panelX1: Int { panelX0 + panelWidth }
    private var panelY1: Int { windowY + panelHeight }

    /// 背景亮度：取画布左上角空白处。
    var backgroundLuma: Double { luma(4, 4) }

    private func luma(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < imageWidth, y < imageHeight,
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return (0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent) * 255
    }

    private func darkness(_ x: Int, _ y: Int) -> Double { backgroundLuma - luma(x, y) }

    /// 面板左右两侧 y∈[0,8]pt 的竖向暗带：取每列最大暗度，返回最差列。
    func sideBandWorst() -> (maxDark: Double, worstX: Double, columns: String) {
        let bg = backgroundLuma
        var worst = (dark: 0.0, x: panelX0)
        var parts: [String] = []
        let columns = Array((panelX0 - 14)..<panelX0) + Array(panelX1..<(panelX1 + 14))
        for x in columns {
            guard x >= 0, x < imageWidth else { continue }
            var maxDark = 0.0
            for y in windowY..<(windowY + 16) {
                maxDark = max(maxDark, bg - luma(x, y))
            }
            if maxDark > worst.dark { worst = (maxDark, x) }
            parts.append(String(format: "%.1f:%.1f", Double(x - windowX) / 2, maxDark))
        }
        return (worst.dark, Double(worst.x - windowX) / 2, parts.joined(separator: " "))
    }

    /// 顶边：y=0..1pt 面板外侧是否有暗线，以及 y<0（窗口顶边以上）是否有外溢。
    func topEdgeDarkness() -> (atTopRow: Double, above: Double) {
        let bg = backgroundLuma
        var atTopRow = 0.0
        for y in windowY...(windowY + 1) {
            for x in (windowX - 16)..<(windowX + windowWidth + 16) where x < panelX0 || x >= panelX1 {
                atTopRow = max(atTopRow, bg - luma(x, y))
            }
        }
        var above = 0.0
        for y in (windowY - 20)..<windowY {
            for x in (windowX - 16)..<(windowX + windowWidth + 16) {
                above = max(above, bg - luma(x, y))
            }
        }
        return (atTopRow, above)
    }

    /// 底部阴影：沿面板中轴列向下扫描，量最大扩散距离与峰值不透明度。
    func bottomSpread() -> (spread: Double, peakDark: Double, peakAlpha: Double, peakOffset: Double) {
        let bg = backgroundLuma
        let centerX = (panelX0 + panelX1) / 2
        var peakDark = 0.0
        var peakRow = panelY1
        var lastDarkRow = panelY1
        for y in panelY1..<min(imageHeight, panelY1 + 220) {
            let dark = darkness(centerX, y)
            if dark > peakDark { peakDark = dark; peakRow = y }
            if dark > 2 { lastDarkRow = y }
        }
        return (
            Double(lastDarkRow - panelY1 + 1) / Double(scale),
            peakDark,
            peakDark / bg,
            Double(peakRow - panelY1) / Double(scale)
        )
    }
}

// MARK: - CG 全局空间标定

/// 不做 frame 约束的探针窗口。
///
/// AppKit 默认会把 .normal 级窗口从菜单栏下面推开（实测下移 33pt，正好一个菜单栏高度），
/// 测坐标系时不能带这种偏移，所以直接返回原始 rect。
final class ProbeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// `NSScreen` point 空间 → `CGWindowList` 全局空间的仿射映射。
///
/// 正常机器上这个映射是恒等（scale=1、inset=0）；本机实测是 scale≈0.90 + (73,47) 的居中内缩。
/// 用它把窗口 frame 换算成「合成器应该报出的 bounds」，断言才有确定的期望值。
struct CGSpaceMapper {
    let screen: CGRect
    let scaleX: CGFloat
    let scaleY: CGFloat
    let leftInset: CGFloat
    let topInset: CGFloat
}

extension CGSpaceMapper {
    /// 由两个角落参考窗口的 frame 与 CG bounds 反解映射（用实际 frame，避免被系统挪过也算错）。
    init?(screen: CGRect, lowFrame: CGRect, lowBounds: CGRect,
          highFrame: CGRect, highBounds: CGRect) {
        let dx = highFrame.midX - lowFrame.midX
        let dy = highFrame.midY - lowFrame.midY
        guard screen.width > 1, screen.height > 1, dx > 1, dy > 1 else { return nil }
        let sx = (highBounds.midX - lowBounds.midX) / dx
        // CG 的 y 轴朝下：左下角窗口的 CG 中心 y 更大。
        let sy = (lowBounds.midY - highBounds.midY) / dy
        guard sx > 0.01, sy > 0.01 else { return nil }
        self.init(
            screen: screen,
            scaleX: sx,
            scaleY: sy,
            leftInset: lowBounds.midX - (lowFrame.midX - screen.minX) * sx,
            topInset: highBounds.midY - (screen.maxY - highFrame.midY) * sy
        )
    }

    func map(_ rect: CGRect) -> CGRect {
        CGRect(
            x: leftInset + (rect.minX - screen.minX) * scaleX,
            y: topInset + (screen.maxY - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    var summary: String {
        String(
            format: "scale=%.4f/%.4f inset=%.1f/%.1f desktop=%.1fx%.1f screen=%.1fx%.1f",
            scaleX, scaleY, leftInset, topInset,
            screen.width * scaleX, screen.height * scaleY,
            screen.width, screen.height
        )
    }
}

// MARK: - 肩部像素测量

/// 在闭合形状的 @4x 离屏渲染图上量左右肩部。
///
/// 坐标：设备像素，原点在图像左上角；窗口左上角固定在 (40pt, 40pt)，
/// 形状在窗口内水平居中后再右移 `offset`（闭合缩略图只向右加宽）。
///
/// 期望值不是「另一侧长什么样」，而是 `NotchShape` 的二次曲线解析解：
/// - 顶部圆角 r：`x = r(2t - t²)`、`y = t²r` → 给定 y 求 t 再求 x；
/// - 底部圆角 b：`x = r + b·t²`、`y = (H-b) + b(2t - t²)`。
/// 左右两侧都必须落在同一条曲线上，且互为镜像。
struct ShoulderProbe {
    enum Side {
        case left
        case right
    }

    struct Result {
        let rows: Int
        let maxMirrorDiff: Double
        let mirrorSpread: Double
        let maxCurveError: Double
        let profile: String
    }

    let rep: NSBitmapImageRep
    let shapeSize: CGSize
    let offset: CGFloat
    let scale: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    private var panelX0: Double {
        40 * scale
            + (ScreenGeometry.windowSize.width * scale - shapeSize.width * scale) / 2
            + offset * scale
    }
    private var panelX1: Double { panelX0 + shapeSize.width * scale }
    private var panelY0: Double { 40 * scale }
    private var panelY1: Double { panelY0 + shapeSize.height * scale }

    func cropRect(side: Side, width: CGFloat) -> CGRect {
        let w = width * scale
        let x = side == .left ? panelX0 : panelX1 - w
        let y = panelY0 - 4 * scale
        let h = (shapeSize.height + 12) * scale
        return CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    private func luma(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return (0.299 * color.redComponent + 0.587 * color.greenComponent
            + 0.114 * color.blueComponent) * 255
    }

    /// 该行的左右边界（连续坐标，设备像素）。
    ///
    /// 从两侧向内找第一个「覆盖过半」的像素，再用它和外侧邻居的覆盖率线性插值，
    /// 得到亚像素边界。从外向内找是为了跳过形状内部的缩略图（它比背景暗但不是实心色），
    /// 内部亮度不会影响边界判定。
    private func rowEdges(y: Int, background: Double) -> (left: Double, right: Double)? {
        func coverage(_ x: Int) -> Double {
            guard x >= 0, x < rep.pixelsWide else { return 0 }
            return min(max(1 - luma(x, y) / background, 0), 1)
        }
        /// 由内侧邻居 `previous` 与边界像素 `index` 反插值出覆盖率 = 0.5 的位置。
        func boundary(_ index: Int, _ previous: Int) -> Double {
            let inner = coverage(previous)
            let edge = coverage(index)
            let innerCenter = Double(previous) + 0.5
            let edgeCenter = Double(index) + 0.5
            guard abs(edge - inner) > 0.0001 else { return edgeCenter }
            let t = min(max((0.5 - inner) / (edge - inner), 0), 1)
            return innerCenter + (edgeCenter - innerCenter) * t
        }

        let leftStart = Int(panelX0) - 4
        let leftLimit = Int(panelX0 + 40 * scale)
        var leftPixel: Int?
        var x = leftStart
        while x <= leftLimit {
            if coverage(x) > 0.5 { leftPixel = x; break }
            x += 1
        }
        let rightStart = Int(panelX1) + 4
        let rightLimit = Int(panelX1 - 40 * scale)
        var rightPixel: Int?
        x = rightStart
        while x >= rightLimit {
            if coverage(x) > 0.5 { rightPixel = x; break }
            x -= 1
        }
        guard let leftPixel, let rightPixel, leftPixel < rightPixel else { return nil }
        return (boundary(leftPixel, leftPixel - 1), boundary(rightPixel, rightPixel + 1))
    }

    /// 该行两侧的内缩量（设备像素），以及按路径解析式算出的期望值。
    private func expectedInset(yPt: Double) -> Double {
        let h = Double(shapeSize.height)
        let r = Double(topRadius)
        let b = Double(bottomRadius)
        if yPt <= r {
            let t = (yPt / r).squareRoot()
            return r * (2 * t - t * t)
        }
        if yPt < h - b {
            return r
        }
        let u = min(max((yPt - (h - b)) / b, 0), 1)
        // y = (H-b) + b(2t - t²) → t = 1 - sqrt(1 - u)
        let t = 1 - (1 - u).squareRoot()
        return r + b * t * t
    }

    /// 边缘亮度剖面：肉眼可核对的「两侧抗锯齿是否一致」。
    func edgeProfile(yPt: Double) -> String {
        let y = Int(panelY0 + yPt * scale)
        let background = luma(4, 4)
        guard let bounds = rowEdges(y: y, background: background) else { return "n/a" }
        var parts: [String] = ["背景:\(Int(background))"]
        for offset in [-2, -1, 0, 1, 2] {
            parts.append(String(format: "左%+d:%.0f", offset, luma(Int(bounds.left) + offset, y)))
        }
        for offset in [-2, -1, 0, 1, 2] {
            parts.append(String(format: "右%+d:%.0f", offset, luma(Int(bounds.right) + offset, y)))
        }
        return parts.joined(separator: " ")
    }

    func measure() -> Result {
        let background = luma(4, 4)

        var maxMirror = 0.0
        var minMirror = Double.infinity
        var maxCurve = 0.0
        var rows = 0
        var profileParts: [String] = []

        var y = Int(panelY0)
        while y < Int(panelY1) {
            defer { y += 1 }
            guard let bounds = rowEdges(y: y, background: background) else { continue }
            let leftInset = bounds.left - panelX0
            let rightInset = panelX1 - bounds.right
            let expected = expectedInset(yPt: (Double(y) - panelY0 + 0.5) / Double(scale)) * Double(scale)
            let yPt = (Double(y) - panelY0) / Double(scale)
            rows += 1
            let mirror = abs(leftInset - rightInset)
            maxMirror = max(maxMirror, mirror)
            minMirror = min(minMirror, mirror)
            maxCurve = max(maxCurve, abs(leftInset - expected), abs(rightInset - expected))
            // 顶部 8pt（肩部）按 0.5pt 步长打印，底部 6pt 也打一小段（下圆角对照），
            // 中间长直边段不刷屏。
            let nearTop = yPt < 8
            let nearBottom = yPt > Double(shapeSize.height) - 6
            if (nearTop || nearBottom), abs(yPt - (yPt * 2).rounded() / 2) < 0.01 {
                profileParts.append(String(
                    format: "%.1f:%.2f/%.2f", yPt,
                    leftInset / Double(scale), rightInset / Double(scale)
                ))
            }
        }

        return Result(
            rows: rows,
            maxMirrorDiff: maxMirror,
            mirrorSpread: minMirror.isFinite ? maxMirror - minMirror : 0,
            maxCurveError: maxCurve,
            profile: profileParts.joined(separator: " ")
        )
    }
}

// MARK: - 界面规范静态检查

/// 扫描界面层源文件，发现裸的字号/行高/间距/圆角/颜色就报出来。
///
/// 扫描范围 = `Sources/Brimio` 下**递归**全部 `.swift` 文件 − `exemptions`。
/// 旧实现按 `hasSuffix("View.swift")` 挑文件，导致 `PlayerSettingsWindow.swift`（新增窗口）
/// 与 `ClosedMediaBadge.swift`（闭合态徽标）一行都没被扫过；改成默认全量扫之后，
/// 新加的界面文件不需要登记就会自动进来，豁免必须显式写进清单并说明原因。
///
/// 递归是硬要求：`Generated/Naming.swift` 曾因为「放在子目录」而整份躲过扫描，
/// 等于用位置代替豁免——照这个路子，以后任何人新建 `Views/` 都能整批逃过检查。
/// 现在子目录里的 `.swift` 一样进扫描集，要豁免只能用**相对路径**写进清单。
enum DesignLint {
    struct Rule {
        let name: String
        let pattern: String
        /// 这条规则是否检查「页面内水平内缩」，可用 `horizontalInsetWhitelist` 按行豁免。
        var usesHorizontalInsetWhitelist = false
    }

    struct Result {
        /// 递归发现的全部 `.swift`（含被豁免的）。
        let discoveredFiles: [String]
        /// 实际跑了规则检查的文件。
        let checkedFiles: [String]
        let exemptedFiles: [String]
        let violations: [String]
    }

    /// 源码根 = `#filePath` 所在目录（即 `Sources/Brimio`）。
    static let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// 唯一的豁免清单。键是**相对 `Sources/Brimio` 的路径**：子目录里的文件必须写全路径
    /// （如 `Generated/Naming.swift`），不能靠「不在扫描范围」实现豁免。
    static let exemptions: [(path: String, reason: String)] = [
        ("DesignSystem.swift", "规范本体：这里的字面量就是 token 定义本身"),
        ("main.swift", "CLI / 离屏渲染脚手架：画布尺寸与红色标记线不属于界面规范"),
        (
            "Generated/Naming.swift",
            "机器生成：由 Scripts/naming.sh --emit-swift 产出，不手写样式；要改请改 Config/naming.env"
        ),
    ]

    /// 递归发现的文件数（含被豁免的）。新增任何 `.swift`（含子目录）都会改变这个数字；
    /// 断言它，是为了让「扫描范围悄悄缩小」变成一条 FAIL，而不是静默漏掉。
    /// 18 = 原 17 + `NotchHardware.swift`（禁画矩形单一来源）。
    static let expectedDiscoveredFileCount = 18
    /// 实际检查数 = 发现数 − 豁免数。两个数分开断言：只断言其中一个，
    /// 都可能出现「数量对得上、实际扫的却是另一批文件」的假绿。
    static let expectedCheckedFileCount = 15

    /// 递归列出 root 下全部 `.swift`，返回相对路径（已排序）。
    static func swiftFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path
        let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // 统一解析符号链接：`/var/...` 与 `/private/var/...` 是同一棵树的两种写法，
            // 不解析就会出现「相对路径算不出来、退回绝对路径」的假失败。
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            paths.append(full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent)
        }
        return paths.sorted()
    }

    /// 除 `main.swift`（探针脚本）外，应用源码（含子目录）不允许出现辅助功能 API。
    ///
    /// 「设置窗口没写权限」只是一侧；这条断言保证另一侧也不会漂移：
    /// 一旦有人给拖放或其他功能加上 `AXUIElement` / `AXIsProcessTrusted`，
    /// 要么删掉，要么新增 `PlayerEntry.Permission` case——后者会让
    /// 「each player's stated permission equals what the code requests」立刻 FAIL。
    static func accessibilityAPICalls() -> [String] {
        let sourceDir = sourceRoot
        let names = swiftFiles(under: sourceDir).filter { $0 != "main.swift" }
        var hits: [String] = []
        for name in names {
            let url = sourceDir.appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if trimmed.contains("AXUIElement") || trimmed.contains("AXIsProcessTrusted") {
                    hits.append("\(name):\(index + 1) -> \(trimmed)")
                }
            }
        }
        return hits
    }

    /// 页面层允许出现「水平内缩」的**显式白名单**（SPEC E7）。
    ///
    /// 规则本身仍然扫描这些行，只是允许命中；白名单里的行如果哪天被删/改写，
    /// 清单校验会报「白名单过期」，不会静默失效。清单是代码，改动会进 diff。
    /// 注意：豁免的是「允许出现内缩」这件事，**不豁免裸数字**——写死 4 照样红。
    static let horizontalInsetWhitelist: [(path: String, marker: String, reason: String)] = [
        (
            "ExpandedContentView.swift",
            ".padding(.horizontal, vm.contentHorizontalInset)",
            "骨架层：内容盒左右 23 只在这里注入一次，页面内不得再写水平内边距"
        ),
        (
            "ExpandedContentView.swift",
            ".padding(.horizontal, DesignSystem.Spacing.xs)",
            "E7：设置页入口按钮是整行持久填充面，在 23 内容盒内再内缩 4（254 → 246 @ 27）"
        ),
    ]

    private static let rules: [Rule] = [
        Rule(name: "缩字号（SPEC §7.7.7：凡是 minimumScaleFactor 一律失败）",
             pattern: #"\.minimumScaleFactor\("#),
        Rule(name: "裸字号（应改用 .textStyle(DesignSystem.Typography.xxx)）",
             pattern: #"\.font\(\s*\.system\(\s*size:"#),
        Rule(name: "裸行高（应改用 .textStyle(...)）",
             pattern: #"\.lineSpacing\(\s*-?[0-9]"#),
        Rule(name: "裸内边距（应改用 DesignSystem.Spacing）",
             pattern: #"\.padding\([^)]*?[0-9]"#),
        Rule(name: "页面内裸水平内边距（内容盒由骨架注入一次）",
             pattern: #"\.padding\(\s*\.(?:horizontal|leading|trailing)\s*,\s*-?[0-9]"#,
             usesHorizontalInsetWhitelist: true),
        Rule(name: "页面内裸水平偏移（内容盒由骨架注入一次）",
             pattern: #"\.offset\(\s*x\s*:\s*-?[0-9]"#,
             usesHorizontalInsetWhitelist: true),
        Rule(name: "裸间距（应改用 DesignSystem.Spacing）",
             pattern: #"spacing:\s*-?[0-9]"#),
        Rule(name: "裸尺寸（应改用 DesignSystem.Size / 窗口几何）",
             pattern: #"\.frame\([^)]*?(?:width|height):\s*-?[0-9]"#),
        Rule(name: "裸圆角（应改用 DesignSystem.Radius）",
             pattern: #"cornerRadius:\s*-?[0-9]"#),
        Rule(name: "裸不透明度（颜色请用 DesignSystem.Colors 语义色）",
             pattern: #"\.opacity\(\s*0?\.[0-9]"#),
        Rule(name: "裸颜色（应改用 DesignSystem.Colors）",
             pattern: #"(?:Color\.|\.fill\(\s*\.|\.foregroundStyle\(\s*\.|\.background\(\s*\.|color:\s*\.)(?:white|black|green|red|blue|gray)\b"#),
        Rule(name: "裸 RGB 颜色（应改用 DesignSystem.Colors）",
             pattern: #"Color\(\s*(?:red:|\.sRGB)"#),
    ]

    /// 闭合态的视图层不允许出现文字节点。
    ///
    /// 只扫 `NotchRootView.swift`：闭合黑底与右侧徽标都在这个文件里，展开内容在
    /// `ExpandedContentView.swift`，不参与这条检查。
    static func closedLayerTextNodes() -> [String] {
        let sourceDir = sourceRoot
        let url = sourceDir.appendingPathComponent("NotchRootView.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return source.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return nil }
            guard trimmed.contains("Text(") || trimmed.contains("Label(") else { return nil }
            return "NotchRootView.swift:\(index + 1) -> \(trimmed)"
        }
    }

    /// 全仓扫描（**含豁免文件、含子目录**）：`minimumScaleFactor` 必须为零。
    ///
    /// 这是 SPEC §7.7.7 的硬红线，不看文件性质：main.swift 与 DesignSystem.swift 也不例外。
    /// 针串在运行时拼出来，避免门禁把自己的函数名/字符串字面量当成命中。
    static func minimumScaleFactorHits() -> [String] {
        let needle = "." + "minimumScale" + "Factor" + "("
        let sourceDir = sourceRoot
        var hits: [String] = []
        for name in swiftFiles(under: sourceDir) {
            let url = sourceDir.appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if line.contains(needle) {
                    hits.append("\(name):\(index + 1): \(trimmed)")
                }
            }
        }
        return hits
    }

    /// 递归扫描。`root` / `exemptions` / `horizontalInsetWhitelist` 可注入，
    /// 是为了让 selftest 能在临时目录里造一棵假的源码树，用负向用例证明规则真的会命中。
    static func scanUI(
        root: URL = sourceRoot,
        exemptions: [(path: String, reason: String)] = DesignLint.exemptions,
        horizontalInsetWhitelist: [(path: String, marker: String, reason: String)]
            = DesignLint.horizontalInsetWhitelist
    ) -> Result {
        let all = swiftFiles(under: root)
        let exemptNames = exemptions.map(\.path)
        let checked = all.filter { !exemptNames.contains($0) }

        var violations: [String] = []
        // 豁免清单指向不存在的文件 = 清单过期，必须报出来，不能默默失效。
        for name in exemptNames where !all.contains(name) {
            violations.append("\(name) 写在豁免清单里，但文件不存在（清单过期）")
        }
        // 白名单同样校验：写成代码的豁免一旦对不上实际源码，也要红。
        var allowedMarkers: [String: [String]] = [:]
        for entry in horizontalInsetWhitelist {
            allowedMarkers[entry.path, default: []].append(entry.marker)
            let url = root.appendingPathComponent(entry.path)
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !source.contains(entry.marker) {
                violations.append(
                    "\(entry.path) 白名单过期：找不到「\(entry.marker)」（\(entry.reason)）"
                )
            }
        }

        for name in checked {
            let url = root.appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                violations.append("\(name) 读取失败，未被检查")
                continue
            }
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                // 跳过注释行，避免文档里举例的数字被误判。
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                for rule in rules {
                    if rule.usesHorizontalInsetWhitelist,
                       let markers = allowedMarkers[name],
                       markers.contains(where: { trimmed.contains($0) }) { continue }
                    guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard regex.firstMatch(in: line, range: range) != nil else { continue }
                    violations.append("\(name):\(index + 1): \(rule.name) -> \(trimmed)")
                }
            }
        }
        return Result(
            discoveredFiles: all,
            checkedFiles: checked,
            exemptedFiles: exemptNames.filter { all.contains($0) },
            violations: violations
        )
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
