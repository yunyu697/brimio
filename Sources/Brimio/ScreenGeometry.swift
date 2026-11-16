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

    /// 顶部凹肩的**切点偏移 t**（不是 cornerRadius）。
    ///
    /// 构造（与参照实现同一套）：从左上角起笔逆时针一圈，4 条直线 + 4 条二次贝塞尔；
    /// 顶部角的控制点落在「角点沿顶边内移 t」处、终点 `(t, t)`，于是起点切线水平、
    /// 终点切线垂直。t 同时是 x / y 方向的切点偏移，占一个 t×t 的方区。
    /// 它不是圆弧：二次曲线中点过 `(0.75t, 0.25t)`，比同半径圆弧更贴角点约 6%；
    /// 把它喂进「圆角」通道会得到外凸，只有作为切点偏移才是内凹肩。
    ///
    /// 两态取值（同一路径、两个标量，状态切换时逐帧插值）：
    /// - 闭合 `top 6 / bottom 14`
    /// - 展开 `top 19 / bottom 24`
    ///
    /// 来源 = **参照实现**，不是实测。6→6 标定成立：
    /// 1. 同一构造：控制点 `(t, 0)`、终点 `(t, t)`、起点切线水平（见 `NotchShape`）；
    /// 2. 同一窗口侧口径：宽 = 硬件带 + 4、闭合高 = `safeAreaInsets.top`、顶边贴屏顶；
    ///    本机硬件带 179×32 → 闭合 183×32，与参照一致；
    /// 3. 因此双方参数是同一量纲（切点偏移），没有换算系数，参照的 19 直接映射为我们的 19。
    ///
    /// 仍未实测的是**绝对值**：真机照片量不出肩弧（见 README），6 与 19 都只能算
    /// 「与参照同档」，没有像素证据能独立复核；但两态的比值 19/6 与参照一致。
    static let shoulderTangentOffset: (closed: CGFloat, opened: CGFloat) = (closed: 6, opened: 19)

    /// 四组切点偏移：opened bottom 24 / closed bottom 14；顶部取 `shoulderTangentOffset`。
    static let cornerRadiusInsets: (
        opened: (top: CGFloat, bottom: CGFloat),
        closed: (top: CGFloat, bottom: CGFloat)
    ) = (
        opened: (top: shoulderTangentOffset.opened, bottom: 24),
        closed: (top: shoulderTangentOffset.closed, bottom: 14)
    )

    /// 当前状态的顶部切点偏移：闭合 6 / 展开 19。
    /// 内容的左右内缩由它派生（`PageMetrics.contentHorizontalInset` = t + `NotchHardware.contentGap`），
    /// 与顶部 1pt 遮缝条的横向内缩共用同一个值。
    static func contentInsetExpectation(isOpen: Bool) -> CGFloat {
        isOpen ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

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
        /// 持久屏幕标识（`CGDisplayCreateUUIDFromDisplayID`），只用于缓存分区；
        /// 注入几何时为 nil，缓存改用 `name` 作 key。
        var screenUUID: String? = nil
        /// 设备像素比（2x 屏为 2）。几何量化要用它把点值对齐到整设备像素；
        /// 注入几何时默认 2——注入断言只验证算法，不验证真机像素。
        var backingScaleFactor: CGFloat = 2

        static func from(_ screen: NSScreen) -> Metrics {
            Metrics(
                frame: screen.frame,
                visibleFrameMaxY: screen.visibleFrame.maxY,
                safeAreaTop: screen.safeAreaInsets.top,
                auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxRightWidth: screen.auxiliaryTopRightArea?.width,
                name: screen.localizedName,
                screenUUID: displayUUID(of: screen),
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    /// 把点值量化到整设备像素：2x 屏是 0.5pt 一档，1x 屏是 1pt 一档。
    /// 形状边缘落在半像素上时，最外一列像素只有部分覆盖，浅色背景透出来就是那条白线。
    static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
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

        return CGSize(
            width: min(pixelAligned(width, scale: metrics.backingScaleFactor), maxOpenSize.width),
            height: max(pixelAligned(height, scale: metrics.backingScaleFactor), 1)
        )
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
    ///
    /// 水平方向量化到整设备像素：形状的水平边缘 = 窗口 origin.x + 窗口内居中偏移，
    /// origin.x 落在半像素上时形状最外一列只有部分覆盖，会透出一圈 1 像素的亮线。
    /// 竖向不量化：顶边是屏幕物理边界，那条边必须严格贴 `frame.maxY`；
    /// 高度是固定整点值，y = maxY − height 本身就在设备像素上。
    static func windowFrame(for screen: NSScreen) -> NSRect {
        windowFrame(for: Metrics.from(screen))
    }

    static func windowFrame(for metrics: Metrics) -> NSRect {
        let size = windowSize
        let x = pixelAligned(
            metrics.frame.origin.x + (metrics.frame.width - size.width) / 2,
            scale: metrics.backingScaleFactor
        )
        return NSRect(x: x, y: metrics.frame.maxY - size.height, width: size.width, height: size.height)
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
