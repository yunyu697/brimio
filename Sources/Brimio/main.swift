import AppKit
import CoreGraphics
import SwiftUI

/// AppKit 生命周期入口（不使用 SwiftUI App，避免非 bundle 可执行文件的启动差异）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSLog("[Brimio] no screen available")
            NSApp.terminate(nil)
            return
        }

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
        } else if CommandLine.arguments.contains("--window-probe") {
            runWindowProbe(screen: screen)
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
            let screen = controller.screenForTesting
            let expected = ScreenGeometry.windowFrame(for: screen)

            // 1. 窗口存在且在屏幕顶部
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
            check(panel.frame.maxY == screen.frame.maxY, "window top aligned with screen top", "maxY=\(panel.frame.maxY)")
            check(
                abs(panel.frame.midX - screen.frame.midX) < 0.5,
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
            // 发了长期通行证。`--window-probe` 查清：`window.frame` 316×148 一直没变，
            // 变的是**坐标空间**——本机 CGWindowList 的全局空间里，整块桌面被等比缩小并居中
            // （桌面 1324×862 @ (73,47)，而 display bounds 是 1470×956），
            // 0ms/100ms/500ms/1s/3s 五个时刻完全一致，且不带 hud/utility 样式的对照窗口数值相同，
            // 所以既不是启动瞬时值，也与面板样式无关。
            //
            // 于是断言改成严格版本：
            // a) 与「同 frame、无面板样式」的对照窗口在合成器里必须完全相等（0 容差）；
            // b) 换算到 CG 空间后与 frame 严格对齐（容差 2.5pt：实测残差 1.6pt，来自合成器
            //    对每条边各自取整，同一台机器上稳定）。
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

            // 3. 初始穿透
            check(panel.ignoresMouseEvents, "collapsed window ignores mouse events")
            check(!vm.isOpen, "initial state is closed")
            check(vm.topCornerRadius == 6, "closed state keeps 6pt top corners", "\(vm.topCornerRadius)")

            // 4. 指针进入 -> 延时展开
            controller.handlePointer(inside: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            check(vm.isOpen, "hover opens the notch")
            check(!panel.ignoresMouseEvents, "open window receives mouse events")
            check(vm.notchSize == PageMetrics.shapeSize(for: .home), "open size follows home page content")
            check(panel.frame.size == ScreenGeometry.windowSize, "window frame unchanged after open")
            check(vm.topCornerRadius == 0, "open state has square top corners", "\(vm.topCornerRadius)")

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
            let homeSize = PageMetrics.shapeSize(for: .home)
            let sizeKeys = ExpandedItem.allCases.map { "\($0.shapeSize.width)x\($0.shapeSize.height)" }
            check(
                Set(sizeKeys).count == ExpandedItem.allCases.count,
                "pages have distinct sizes",
                ExpandedItem.allCases.map { "\($0.title)=\(Int($0.shapeSize.width))x\(Int($0.shapeSize.height))" }
                    .joined(separator: " ")
            )
            // 高度必须严格等于「chrome + 间距 + 内容自然高 + 上下同一档 padding」：
            // 一旦某页被下限/中间档夹住，这个等式就不成立。
            let padding = PageMetrics.contentPadding
            let fixedChrome = PageMetrics.chromeHeight + PageMetrics.rowSpacing
            let paddingMath = ExpandedItem.allCases.allSatisfy { item in
                let shape = PageMetrics.shapeSize(for: item)
                return abs(shape.width - (item.contentSize.width + padding * 2)) < 0.001
                    && abs(shape.height - (item.contentSize.height + fixedChrome + padding * 2)) < 0.001
            }
            check(
                paddingMath,
                "all four sides share one padding token",
                ExpandedItem.allCases.map {
                    "\($0.title) 内容\(Int($0.contentSize.width))x\(Int($0.contentSize.height))"
                        + " + chrome\(Int(PageMetrics.chromeHeight)) + 间距\(Int(PageMetrics.rowSpacing))"
                        + " + \(Int(padding))*2 = \(Int($0.shapeSize.width))x\(Int($0.shapeSize.height))"
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
                return abs(b.contentRatio + b.chromeRatio + b.overheadRatio - 1) < 1e-9
            }
            check(
                ratiosSumToOne,
                "the three height shares sum to 100%",
                ExpandedItem.allCases.map {
                    let b = PageMetrics.heightBudget(for: $0)
                    return String(
                        format: "%@ 内容%.1f%% / chrome %.1f%% / padding+间距 %.1f%%",
                        $0.title, b.contentRatio * 100, b.chromeRatio * 100, b.overheadRatio * 100
                    )
                }.joined(separator: "；")
            )
            // 首页是媒体页：实际内容块必须是三个桶里最大的一份，
            // 否则说明 chrome 或留白又比内容还占地方。
            let homeBudget = PageMetrics.heightBudget(for: .home)
            check(
                homeBudget.content > homeBudget.chrome && homeBudget.content > homeBudget.overhead,
                "home content block is the largest of the three shares",
                String(
                    format: "内容 %.1f%% (%d/%d) > padding+间距 %.1f%% > chrome %.1f%%",
                    homeBudget.contentRatio * 100,
                    Int(homeBudget.content), Int(homeBudget.total),
                    homeBudget.overheadRatio * 100, homeBudget.chromeRatio * 100
                )
            )
            // 份额下限对**每一页**生效：内容块不得低于面板高度的 30%。
            // 豁免页写死在 PageMetrics.contentShareExemptions 里，这里逐页打印。
            for item in ExpandedItem.allCases {
                print("[SHARE] \(PageMetrics.contentShareReport(for: item))")
            }
            let belowFloor = ExpandedItem.allCases.filter { !PageMetrics.contentShareVerdict(for: $0).passes }
            check(
                belowFloor.isEmpty,
                "every page keeps content above \(Int(PageMetrics.minContentRatio * 100))% of panel height",
                ExpandedItem.allCases.map { PageMetrics.contentShareReport(for: $0) }.joined(separator: "；")
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
            // 尺寸表来自 DESIGN.md：空架/1 条 104，2 条 144，3 条 184，≥4 条 212（视口 140）。
            // 逐状态打印，方便和文档表格逐行核对。
            let shelfStates: [(count: Int, height: CGFloat)] = [
                (0, 104), (1, 104), (2, 144), (3, 184), (4, 212)
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
                "file shelf holds its size and content share in all five states",
                shelfStateLines.joined(separator: "；")
            )
            check(
                PageMetrics.maxSize.height == 212,
                "panel height cap stays at 212pt",
                "\(Int(PageMetrics.maxSize.height))pt"
            )
            // 文件架的高度必须真的跟着条目数走：否则上面五条会一起退化成同一个值。
            let shelfHeights = shelfStates.map {
                PageMetrics.shapeSize(for: .files, shelfCount: $0.count).height
            }
            check(
                shelfHeights == [104, 104, 144, 184, 212],
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
            // 负向用例：递归必须真的生效。临时目录里造 `Views/FakeView.swift`（含裸数值），
            // 若扫描退回「只列顶层目录」，这个文件根本不会被发现，这条就会 FAIL。
            let probeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lint-recursive-probe-\(UUID().uuidString)", isDirectory: true)
            let probeSub = probeRoot.appendingPathComponent("Views", isDirectory: true)
            try? FileManager.default.createDirectory(at: probeSub, withIntermediateDirectories: true)
            try? "struct FakeView: View { var body: some View { Text(\"x\").padding(8) } }"
                .write(
                    to: probeSub.appendingPathComponent("FakeView.swift"),
                    atomically: true,
                    encoding: .utf8
                )
            let probe = DesignLint.scanUI(root: probeRoot, exemptions: [])
            let probeHit = probe.violations.contains { $0.hasPrefix("Views/FakeView.swift") }
            check(
                probe.discoveredFiles == ["Views/FakeView.swift"] && probeHit,
                "recursion proven by a negative case in a temp subdirectory",
                "discovered=\(probe.discoveredFiles.count) violations=\(probe.violations.count) "
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

            if failures.isEmpty {
                print("[SELFTEST] PASS all \(total) checks")
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
            let pass = openResult.sizeIntermediate >= 3 && closeResult.sizeIntermediate >= 3
                && openResult.shapeIntermediate >= 3 && closeResult.shapeIntermediate >= 3
                && contained
            print(pass
                  ? "[ANIM] PASS animation interpolates: open size=\(openResult.sizeIntermediate) shape=\(openResult.shapeIntermediate),"
                    + " close size=\(closeResult.sizeIntermediate) shape=\(closeResult.shapeIntermediate), contained=true"
                  : "[ANIM] FAIL: open size=\(openResult.sizeIntermediate) shape=\(openResult.shapeIntermediate),"
                    + " close size=\(closeResult.sizeIntermediate) shape=\(closeResult.shapeIntermediate), contained=\(contained)")
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
        scale: CGFloat = 2
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
            Color(red: 0.62, green: 0.64, blue: 0.67)
            NotchRootView(
                vm: vm,
                onTap: {},
                onSelect: { _ in },
                onMediaControl: { _ in },
                onOpenPlayerSettings: {},
                onDropFiles: { _ in }
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
        // 兼容旧命名：open.png = 首页。
        jobs.append(("open.png", true, .home, .playing, 0))

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
                ? PageMetrics.shapeSize(for: job.route, shelfCount: job.shelf)
                : CGSize(width: closedWidth, height: ScreenGeometry.closedSize(for: screen).height)
            let url = dir.appendingPathComponent(job.name)
            do {
                try png.write(to: url)
                let detail = job.open
                    ? " content=\(Int(job.route.contentSize.width))x"
                        + "\(Int(PageMetrics.contentHeight(for: job.route, shelfCount: job.shelf)))"
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
            let closedRect = ScreenGeometry.closedRect(for: controller.screenForTesting)
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
    static let expectedDiscoveredFileCount = 17
    /// 实际检查数 = 发现数 − 豁免数。两个数分开断言：只断言其中一个，
    /// 都可能出现「数量对得上、实际扫的却是另一批文件」的假绿。
    static let expectedCheckedFileCount = 14

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

    private static let rules: [Rule] = [
        Rule(name: "裸字号（应改用 .textStyle(DesignSystem.Typography.xxx)）",
             pattern: #"\.font\(\s*\.system\(\s*size:"#),
        Rule(name: "裸行高（应改用 .textStyle(...)）",
             pattern: #"\.lineSpacing\(\s*-?[0-9]"#),
        Rule(name: "裸内边距（应改用 DesignSystem.Spacing）",
             pattern: #"\.padding\([^)]*?[0-9]"#),
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

    /// 递归扫描。`root` / `exemptions` 可注入，是为了让 selftest 能在临时目录里
    /// 造一棵假的源码树，用负向用例证明「子目录确实会被扫到」。
    static func scanUI(
        root: URL = sourceRoot,
        exemptions: [(path: String, reason: String)] = DesignLint.exemptions
    ) -> Result {
        let all = swiftFiles(under: root)
        let exemptNames = exemptions.map(\.path)
        let checked = all.filter { !exemptNames.contains($0) }

        var violations: [String] = []
        // 豁免清单指向不存在的文件 = 清单过期，必须报出来，不能默默失效。
        for name in exemptNames where !all.contains(name) {
            violations.append("\(name) 写在豁免清单里，但文件不存在（清单过期）")
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
                    guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard regex.firstMatch(in: line, range: range) != nil else { continue }
                    violations.append("\(name):\(index + 1) \(rule.name) -> \(trimmed)")
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
