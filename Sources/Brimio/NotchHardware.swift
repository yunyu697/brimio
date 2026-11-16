import AppKit
import CoreGraphics

/// 刘海硬件占据的矩形，**唯一来源**。
///
/// 只从这里取边界，其他任何地方都不许再用「闭合宽度 − 4」之类的反推去凑：
/// 那 4pt 是形状的抗锯齿补偿，不是安全边距。
enum NotchHardware {
    /// 内容与硬件边缘之间必须留出的最小间隙（取设计 token，不再写魔法数）。
    static let contentGap: CGFloat = DesignSystem.Spacing.xs
    /// 机型标识，**只用于诊断输出与合理性交叉校验**，不参与任何行为判定。
    static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
    /// 形状允许超出硬件带的**总宽**上限：2pt/边的抗锯齿补偿。
    ///
    /// 这 4pt 只用于让最外一列像素压在同色上（见 `DesignSystem.Size.overscan` 的说明），
    /// **不承载任何内容**。超过它就是真的把像素画到菜单栏上。
    /// 决策 D1（2026-11-16，项目所有者拍板）：闭合态宽度上限 = 硬件带 + 本补偿。
    static let antialiasAllowance: CGFloat = 4

    /// 形状本体为抗锯齿向硬件内伸出的量；这是设计内行为，断言只豁免这一圈。
    static func antialiasOverhang(closedWidth: CGFloat, hardwareWidth: CGFloat) -> CGFloat {
        max(0, (closedWidth - hardwareWidth) / 2)
    }

    struct Box: Equatable {
        /// 屏幕坐标系下的硬件矩形。
        var rect: CGRect
        /// 左右辅助区缺失或测量不合理、宽度是按兜底规则估出来时为 true。
        var isEstimated: Bool
        /// 估算原因；实测通过时为 nil。
        var reason: String?
    }

    // MARK: - 缓存

    /// 缓存条目：key 覆盖「屏幕标识 + 帧 + 刘海相关信号」。
    /// 同一配置只算一次；配置一变 key 就不命中，同时系统通知会主动清空。
    private static var cache: (key: String, box: Box?)?
    /// 读屏缓存：key 只取标识/帧/刘海高度，命中时连 auxiliary 区都不再读。
    private static var screenCache: (key: String, snapshot: Snapshot)?
    /// 真正的计算次数。自测用它证明第二次调用没有重复计算。
    private(set) static var computeCount = 0
    /// 从 `NSScreen` 读取 auxiliary / inset 的次数（命中读屏缓存时不再增加）。
    private(set) static var readCount = 0

    /// 一次读取的结果：几何输入 + 由它算出的矩形。
    struct Snapshot {
        let metrics: ScreenGeometry.Metrics
        let box: Box?
    }

    static func screenKey(for metrics: ScreenGeometry.Metrics) -> String {
        let left = metrics.auxLeftWidth.map { String(format: "%.3f", $0) } ?? "nil"
        let right = metrics.auxRightWidth.map { String(format: "%.3f", $0) } ?? "nil"
        return "\(metrics.screenUUID ?? metrics.name)"
            + "|\(metrics.frame.minX),\(metrics.frame.minY),\(metrics.frame.width)x\(metrics.frame.height)"
            + "|top=\(metrics.safeAreaTop)|aux=\(left)/\(right)"
    }

    /// 生产路径：按屏幕缓存。key 只取标识 + 帧 + `safeAreaInsets.top`（廉价读数），
    /// 命中时不再读 auxiliary 区。不同屏幕 key 不同，不会跨屏串用。
    static func snapshot(for screen: NSScreen) -> Snapshot {
        let key = "\(ScreenGeometry.displayUUID(of: screen) ?? screen.localizedName)"
            + "|\(screen.frame.minX),\(screen.frame.minY),\(screen.frame.width)x\(screen.frame.height)"
            + "|top=\(screen.safeAreaInsets.top)"
        if let screenCache, screenCache.key == key { return screenCache.snapshot }
        readCount += 1
        let metrics = ScreenGeometry.Metrics.from(screen)
        let snapshot = Snapshot(metrics: metrics, box: box(for: metrics))
        screenCache = (key, snapshot)
        return snapshot
    }

    static func invalidateCache() {
        cache = nil
        screenCache = nil
    }

    /// 自测用：清空计数，不影响已缓存的结果。
    static func resetCacheCounters() {
        computeCount = 0
        readCount = 0
    }

    /// 有刘海才有矩形；`safeAreaTop == 0` 返回 nil，表示不设禁画区。
    ///
    /// 判定只用系统信号（`safeAreaInsets.top > 0`），**不设机型白名单**：
    /// `hw.model` 只做诊断输出与合理性交叉校验。白名单的失败模式是「表里没有的机型」
    /// 被当成无刘海，从而静默不设禁画区、直接压硬件；而这恰恰是要防的事。
    static func box(for metrics: ScreenGeometry.Metrics) -> Box? {
        box(for: metrics, key: screenKey(for: metrics))
    }

    private static func box(for metrics: ScreenGeometry.Metrics, key: String) -> Box? {
        if let cache, cache.key == key { return cache.box }
        computeCount += 1
        let box = computeBox(for: metrics)
        cache = (key, box)
        return box
    }

    private static func computeBox(for metrics: ScreenGeometry.Metrics) -> Box? {
        guard metrics.safeAreaTop > 0 else { return nil }
        let originY = metrics.frame.maxY - metrics.safeAreaTop
        let screenWidth = metrics.frame.width
        var reason: String?

        if let left = metrics.auxLeftWidth, let right = metrics.auxRightWidth {
            let width = screenWidth - left - right
            let ratio = width / screenWidth
            let asymmetry = abs(left - right)
            if width <= 0 {
                reason = "宽度非正"
            } else if ratio < 0.08 || ratio > 0.25 {
                reason = "宽度占屏比 \(ratio) 超出 0.08…0.25"
            } else if asymmetry > max(2, screenWidth * 0.002) {
                reason = "左右辅助区不对称 \(asymmetry)pt"
            } else if metrics.safeAreaTop < 24 || metrics.safeAreaTop > 48 {
                reason = "刘海高度 \(metrics.safeAreaTop)pt 超出 24…48"
            }
            if reason == nil {
                return Box(
                    rect: CGRect(
                        x: metrics.frame.minX + left,
                        y: originY,
                        width: width,
                        height: metrics.safeAreaTop
                    ),
                    isEstimated: false,
                    reason: nil
                )
            }
        } else {
            reason = "auxiliary 区域为 nil"
        }

        // 保守收缩：取「实测与兜底中的较大者」，宁可留白也不压硬件。
        let derived = ScreenGeometry.closedSize(for: metrics).width - 4
        let width = max(ScreenGeometry.fallbackNotchWidth, derived)
        return Box(
            rect: CGRect(
                x: metrics.frame.midX - width / 2,
                y: originY,
                width: width,
                height: metrics.safeAreaTop
            ),
            isEstimated: true,
            reason: reason
        )
    }

    /// 内容需要让出的水平半宽；估算时天然取较大者。
    ///
    /// **凡是依赖矩形宽度的让位都必须走这里**（闭合态徽标、以后任何贴边的槽位），
    /// 不许在别处用「闭合宽度 − 4」自己反推。估算态的矩形宽度已经是
    /// `max(实测, 兜底)`，所以这一条口径同时覆盖实测与退化两条路径。
    static func clearanceHalfWidth(for metrics: ScreenGeometry.Metrics) -> CGFloat? {
        box(for: metrics).map { $0.rect.width / 2 }
    }

    /// 展开态内容必须让出的顶部内边距：矩形下缘 + `contentGap`，且不小于统一内边距。
    ///
    /// 竖向让位是展开态唯一的一条规则（不按页特判）：chrome 行与页面内容整体压到
    /// 硬件矩形之下，水平位置因此不再承担避让职责。
    /// 没有矩形（无刘海 / `safeAreaTop == 0`）时退回统一内边距。
    static func topInset(for metrics: ScreenGeometry.Metrics) -> CGFloat {
        guard let box = box(for: metrics) else { return DesignSystem.Spacing.lg }
        return max(DesignSystem.Spacing.lg, box.rect.height + contentGap)
    }
}
