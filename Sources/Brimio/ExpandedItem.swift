import Foundation

/// 展开态的内容路由。
///
/// 加一个页面只需要在这里加一个 case（以及 `title` / `iconName` / 尺寸描述的分支），
/// 视图结构（唯一一行 chrome + 页面容器）保持不变：
/// Tab 栏由 `allCases` 生成，页面容器按 `route` 选中对应分支。
enum ExpandedItem: String, CaseIterable, Identifiable, Equatable {
    case home
    case files
    case timer
    case players

    var id: String { rawValue }

    /// Tab 的无障碍标签。图标化之后文字不再上屏，只留给 VoiceOver。
    var title: String {
        switch self {
        case .home: return "首页"
        case .files: return "文件架"
        case .timer: return "计时器"
        case .players: return "播放器兼容"
        }
    }

    /// Tab 图标（SF Symbols）。
    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .files: return "folder.fill"
        case .timer: return "timer"
        case .players: return "slider.horizontal.3"
        }
    }

    /// 该页内容区的**自然尺寸**（不含统一内边距）。
    ///
    /// 尺寸描述跟着路由走，不写死在视图里：视图只负责把内容填进这个区域，
    /// 面板形状的宽高由 `PageMetrics` 统一换算。
    var contentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    /// 内容区宽度：设计声明的阅读宽度，决定面板有多宽。
    private var contentWidth: CGFloat {
        switch self {
        // 首页：封面 56 + 间距 8 + 文字 112 + 间距 8 + 控制 84 = 268
        case .home: return 268
        case .files: return 216
        case .timer: return 196
        // 播放器兼容：每行「名字 + 开关 + 一行权限/收益说明」需要更宽的行宽。
        case .players: return 268
        }
    }

    /// 内容区的**自然高度**：按 token 累加，不补到任何中间档。
    var contentHeight: CGFloat {
        switch self {
        // 首页：媒体行 = 封面位 56（文字两行 18 + 4 + 15 居中，控制按钮 28 居中）
        case .home:
            return DesignSystem.Size.cover
        // 文件架：空状态虚线框一行高（控件阶梯 lg = 32，文字在框内居中）
        case .files:
            return DesignSystem.Control.lg
        // 计时器：占位一行正文 15
        case .timer:
            return DesignSystem.Typography.body.lineHeight
        // 播放器兼容：固定高度内滚动（4 行 × 28pt）。
        // chrome+间距+四边内边距是 72pt，212 上限留给内容 140，取 112 保证不被夹住。
        case .players:
            return DesignSystem.Control.md * 4
        }
    }

    /// 该页的形状尺寸（chrome + 内容 + 统一内边距，夹在上下限内）。
    var shapeSize: CGSize { PageMetrics.shapeSize(for: self) }
}

/// 展开态尺寸的统一换算：内容尺寸 → 形状尺寸。
///
/// 规则：形状 = 固定骨架 + 内容自然尺寸 + 四边统一内边距，再夹在上下限之间。
/// 上下限只防两个极端（窄到放不下 Header/Tab、单页内容把面板撑爆），
/// 不再有「页面内容区最小高度」这种会把不同内容拉平的中间档。
enum PageMetrics {
    /// 统一内边距，四边一致（复用间距阶梯的 lg = 16）。
    /// 视图层整块 `.padding(contentPadding)`，不再分别写 top/horizontal。
    static let contentPadding = DesignSystem.Spacing.lg

    /// 唯一一行 chrome 的高度：28pt（Tab 图标行，标题与状态文字都已删除）。
    static let chromeHeight = DesignSystem.Control.md
    /// chrome 行与内容区之间的间距（用间距而不是分隔线分组）。
    static let rowSpacing = DesignSystem.Spacing.md

    /// 一页的高度预算：三个互不重叠的桶，相加正好等于面板高度。
    ///
    /// 旧的口径把 chrome 与底部 padding 也算进「内容区」，报出 80.6% 的同时又说
    /// chrome 占 19.4%，自相矛盾。这里拆成三个独立数字，分母都是面板总高。
    struct HeightBudget {
        /// 实际内容块高度（首页媒体行 / 文件架空状态框 / 计时器常驻行）。
        let content: CGFloat
        /// 唯一一行 chrome。
        let chrome: CGFloat
        /// 上下内边距 + chrome 与内容之间的间距。
        let overhead: CGFloat

        var total: CGFloat { content + chrome + overhead }
        var contentRatio: Double { Double(content / total) }
        var chromeRatio: Double { Double(chrome / total) }
        var overheadRatio: Double { Double(overhead / total) }
    }

    static func heightBudget(for item: ExpandedItem, shelfCount: Int = 0) -> HeightBudget {
        HeightBudget(
            content: contentHeight(for: item, shelfCount: shelfCount),
            chrome: chromeHeight,
            overhead: contentPadding * 2 + rowSpacing
        )
    }

    /// 内容高度：文件架按条目数变化（0/1、2、3、≥4 四档），其余页取自然高度。
    static func contentHeight(for item: ExpandedItem, shelfCount: Int = 0) -> CGFloat {
        guard item == .files else { return item.contentHeight }
        return FileShelfLayout.contentHeight(count: shelfCount)
    }

    // MARK: - 内容份额下限（每一页都生效）

    /// 内容块占面板高度的下限：**30%**。
    ///
    /// 固定骨架 = chrome 28 + 上下内边距 32 + 行间距 12 = 72pt，任何一页都要先付这笔钱，
    /// 它不承载任何内容。30% 折算成内容高度约 31pt，正好等于「两条正文行高（15×2）」
    /// 或一个控件档位（32）——低于这个量级，继续把面板加高只是在放大留白，
    /// 也就是产品原则里的「无效内容不能占一半以上」的量化口径。
    static let minContentRatio: Double = 0.30

    /// 允许低于下限的页面。豁免必须写在这里（而不是在断言里悄悄跳过），
    /// `--selftest` 会逐页打印份额并把豁免原因一起打出来。
    struct ContentShareExemption {
        let item: ExpandedItem
        let reason: String
    }

    static let contentShareExemptions: [ContentShareExemption] = [
        ContentShareExemption(
            item: .timer,
            reason: "占位页：内容只有一行「后续接入」（15pt）。72pt 固定骨架下上限就是 17.2%，"
                + "把形状压到最小档 72pt 也只是把留白换成骨架，份额不会变好"
        ),
    ]

    struct ContentShareVerdict {
        let ratio: Double
        let content: CGFloat
        let total: CGFloat
        /// 非 nil 表示这一页被显式豁免，值为原因。
        let exemption: String?

        var passes: Bool { ratio >= minContentRatio || exemption != nil }
    }

    static func contentShareVerdict(for item: ExpandedItem, shelfCount: Int = 0) -> ContentShareVerdict {
        let budget = heightBudget(for: item, shelfCount: shelfCount)
        return ContentShareVerdict(
            ratio: budget.contentRatio,
            content: budget.content,
            total: budget.total,
            exemption: contentShareExemptions.first { $0.item == item }?.reason
        )
    }

    /// 一行报告：`首页 内容 43.8% (56/128) ≥ 下限 30%`；豁免页尾巴上带原因。
    static func contentShareReport(for item: ExpandedItem, shelfCount: Int = 0) -> String {
        let verdict = contentShareVerdict(for: item, shelfCount: shelfCount)
        let label = item == .files ? "文件架 \(shelfCount) 个" : item.title
        let head = String(
            format: "%@ 内容 %.1f%% (%d/%d)",
            label, verdict.ratio * 100, Int(verdict.content), Int(verdict.total)
        )
        if let exemption = verdict.exemption {
            return "\(head) 豁免：\(exemption)"
        }
        return "\(head) ≥ 下限 \(Int(minContentRatio * 100))%"
    }

    /// 下限：高度至少要放得下 chrome 行 + 间距 + 上下内边距（内容高度可以为 0）。
    static let minSize = CGSize(
        width: 200,
        height: chromeHeight + rowSpacing + contentPadding * 2
    )
    /// 上限：单页内容过大时的封顶值，保证窗口不会被一页撑爆。
    /// 212pt 是文件架「3 整行 + 第 4 行露出 20pt」所需的高度；
    /// 不做「4 条整行」的 224——那已脱离刘海形态。
    static let maxSize = CGSize(width: 640, height: 212)

    static func shapeSize(for item: ExpandedItem, shelfCount: Int = 0) -> CGSize {
        let content = item.contentSize
        return CGSize(
            width: min(max(content.width + contentPadding * 2, minSize.width), maxSize.width),
            height: min(
                max(
                    contentHeight(for: item, shelfCount: shelfCount)
                        + chromeHeight + rowSpacing + contentPadding * 2,
                    minSize.height
                ),
                maxSize.height
            )
        )
    }

    /// 所有页面里最大的形状尺寸：窗口按它固定，切页只改内容不改窗口。
    /// 文件架按溢出态（4 条）计算，否则窗口会被一屏之外的内容裁掉。
    static var maxShapeSize: CGSize {
        ExpandedItem.allCases.reduce(CGSize.zero) { partial, item in
            let size = shapeSize(for: item, shelfCount: overflowShelfCount)
            return CGSize(width: max(partial.width, size.width), height: max(partial.height, size.height))
        }
    }

    /// 溢出态条目数：一屏 3 条，第 4 条触发滚动。
    static var overflowShelfCount: Int { FileShelfLayout.visibleRows + 1 }
}
