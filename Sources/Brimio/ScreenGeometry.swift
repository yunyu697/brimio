import AppKit
import CoreGraphics

/// 屏幕几何：刘海判定、闭合/展开尺寸、窗口与命中矩形。
/// 每个常量都注明取值依据（完整推导见 README「几何与动效的取值依据」）。
enum ScreenGeometry {
    /// 窗口比展开内容多留的底部空间，用来给 SwiftUI 的阴影绘制留余量。
    /// 取 20：阴影 radius 4 + 下移 2 之后四周仍要留白，20pt 足够容纳底部实测 8pt 的扩散。
    static let shadowPadding: CGFloat = 20
    /// 展开态最大形状尺寸 = 所有页面里最大的那个（尺寸随内容决定，见 `PageMetrics`）。
    /// 窗口按这个最大值固定，页面再小也不改窗口 frame。
    static var maxOpenSize: CGSize { PageMetrics.maxShapeSize }

    /// 动画超调余量。
    /// 宽度也参与动画（183 ↔ 最大页宽），而开合 spring（0.42 / 0.8，欠阻尼）
    /// 对宽度会有约 1.2% 的超调。窗口宽度按「最大页宽 + 16pt」给足余量，
    /// 保证整段动画（含切页时的宽度变化）都落在窗口内。
    /// 超调那几帧必须落在窗口里，否则会被窗口边界平切。
    static let animationOvershootPadding: CGFloat = 16

    /// 窗口尺寸：固定不变，开合/切页只改 SwiftUI 内容尺寸。
    /// 宽度 = 最大页宽 + animationOvershootPadding，高度 = 最大页高 + shadowPadding。
    static var windowSize: CGSize {
        CGSize(
            width: maxOpenSize.width + animationOvershootPadding,
            height: maxOpenSize.height + shadowPadding
        )
    }

    /// 四组圆角：opened top 19 / bottom 24，closed top 6 / bottom 14。
    /// 实际生效的展开态顶部圆角是 0（见 `NotchViewModel.topCornerRadius`）：面板顶边压在屏幕顶边上，
    /// 正圆角会在顶边与形状之间露出两个背景三角。
    static let cornerRadiusInsets: (
        opened: (top: CGFloat, bottom: CGFloat),
        closed: (top: CGFloat, bottom: CGFloat)
    ) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

    /// 无刘海屏的兜底刘海宽度。
    /// 185：无刘海屏没有物理刘海可对齐，这个宽度与菜单栏图标密度下的视觉重心相称。
    static let fallbackNotchWidth: CGFloat = 185
    /// 无刘海屏的自定义高度。
    /// 32：与标准菜单栏等高，闭合形状正好嵌在菜单栏里。
    static let nonNotchHeight: CGFloat = 32
    /// 有刘海屏的自定义高度（本项目没有设置界面，只作为 custom 模式的默认值）。
    /// 32：与物理刘海高度一致。
    static let notchHeight: CGFloat = 32

    // MARK: - 几何输入（可注入）

    /// 把「屏幕」抽象成一组数值。生产路径从 `NSScreen` 取，selftest 可以注入固定值，
    /// 这样无屏 runner 上也能真跑几何断言，而不是静默跳过。
    struct Metrics: Equatable {
        var frame: CGRect
        var visibleFrameMaxY: CGFloat
        var safeAreaTop: CGFloat
        var auxLeftWidth: CGFloat?
        var auxRightWidth: CGFloat?
        var name: String

        static func from(_ screen: NSScreen) -> Metrics {
            Metrics(
                frame: screen.frame,
                visibleFrameMaxY: screen.visibleFrame.maxY,
                safeAreaTop: screen.safeAreaInsets.top,
                auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxRightWidth: screen.auxiliaryTopRightArea?.width,
                name: screen.localizedName
            )
        }
    }

    /// 只有显式传入 `--headless-geometry=...`（或环境变量）时才非空。
    /// 默认 `nil`，生产路径不会走到注入分支。
    static var injected: Metrics?

    /// 当前几何 + 来源标签。`source=injected` 表示确实走了注入路径。
    static func current() -> (metrics: Metrics, source: String)? {
        if let injected { return (injected, "injected") }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return (Metrics.from(screen), "NSScreen")
        }
        return nil
    }

    // MARK: - 刘海判定

    static func hasNotch(_ screen: NSScreen) -> Bool {
        hasNotch(Metrics.from(screen))
    }

    static func hasNotch(_ metrics: Metrics) -> Bool {
        metrics.safeAreaTop > 0
    }

    /// 刘海高度取值方式。
    /// 三种模式：有刘海取真实高度，无刘海取菜单栏高度，custom 留给将来的设置项。
    enum NotchHeightMode {
        case matchRealNotchSize
        case matchMenuBar
        case custom(CGFloat)
    }

    /// 闭合态尺寸：宽度用两侧 auxiliary 区域反推并 +4 补偿；高度按三种模式取值。
    /// 宽度交给屏幕自己算，任何机型都自适应，不需要按机型查表。
    static func closedSize(
        for screen: NSScreen,
        heightMode: NotchHeightMode? = nil
    ) -> CGSize {
        closedSize(for: Metrics.from(screen), heightMode: heightMode)
    }

    /// 与上面同一个算法，输入换成可注入的 `Metrics`。
    static func closedSize(
        for metrics: Metrics,
        heightMode: NotchHeightMode? = nil
    ) -> CGSize {
        var width = fallbackNotchWidth
        if let left = metrics.auxLeftWidth, let right = metrics.auxRightWidth {
            // +4 是四处各 1pt 的抗锯齿补偿：刘海边缘落在半像素上，不补会在与菜单栏之间露出 1px 亮缝。
            width = metrics.frame.width - left - right + 4
        }

        // 默认：有刘海屏取真实刘海高度，无刘海屏取菜单栏高度。
        let mode = heightMode ?? (hasNotch(metrics) ? .matchRealNotchSize : .matchMenuBar)
        let height: CGFloat
        switch mode {
        case .matchRealNotchSize:
            height = hasNotch(metrics) ? metrics.safeAreaTop : nonNotchHeight
        case .matchMenuBar:
            height = menuBarHeight(for: metrics)
        case .custom(let value):
            height = value
        }

        return CGSize(width: min(width, maxOpenSize.width), height: max(height, 1))
    }

    /// 菜单栏高度：`frame.maxY - visibleFrame.maxY`。
    /// 这是 AppKit 里唯一可靠的来源；24pt 下限防止隐藏菜单栏等状态下算出 0。
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        menuBarHeight(for: Metrics.from(screen))
    }

    static func menuBarHeight(for metrics: Metrics) -> CGFloat {
        max(metrics.frame.maxY - metrics.visibleFrameMaxY, 24)
    }

    // MARK: - 矩形计算

    /// 屏幕顶部居中的矩形（AppKit 坐标：原点左下，y 向上）。
    static func rectAtTopCenter(size: CGSize, on screen: NSScreen) -> NSRect {
        rectAtTopCenter(size: size, on: Metrics.from(screen))
    }

    static func rectAtTopCenter(size: CGSize, on metrics: Metrics) -> NSRect {
        NSRect(
            x: metrics.frame.origin.x + (metrics.frame.width - size.width) / 2,
            y: metrics.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 窗口矩形：固定 windowSize，顶边贴屏幕顶边、水平居中。
    static func windowFrame(for screen: NSScreen) -> NSRect {
        windowFrame(for: Metrics.from(screen))
    }

    static func windowFrame(for metrics: Metrics) -> NSRect {
        rectAtTopCenter(size: windowSize, on: metrics)
    }

    /// 闭合态的命中矩形（也就是视觉上的刘海）。
    static func closedRect(for screen: NSScreen) -> NSRect {
        closedRect(for: Metrics.from(screen))
    }

    static func closedRect(for metrics: Metrics) -> NSRect {
        rectAtTopCenter(size: closedSize(for: metrics), on: metrics)
    }

    /// 展开态形状矩形（按传入页面尺寸；命中与阴影都用它，而不是窗口矩形）。
    static func openRect(for screen: NSScreen, size: CGSize) -> NSRect {
        openRect(for: Metrics.from(screen), size: size)
    }

    static func openRect(for metrics: Metrics, size: CGSize) -> NSRect {
        rectAtTopCenter(size: size, on: metrics)
    }

    // MARK: - 屏幕标识

    /// 用 CGDisplay 的持久 UUID 标识屏幕，避免热插拔后索引错位。
    static func displayUUID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
