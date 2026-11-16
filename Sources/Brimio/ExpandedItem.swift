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
    /// 面板宽 = 内容宽 + 2×`openContentHorizontalInset`(23)；顶部 t=19 后内容让位 14pt、
    /// 面板宽保持 300 / 248 / 228 / 300 不变。
    private var contentWidth: CGFloat {
        switch self {
        // 首页：封面 56 + 间距 8 + 文字 98 + 间距 8 + 控制 84 = 254
        case .home: return 254
        case .files: return 202
        case .timer: return 182
        // 播放器兼容：每行「名字 + 开关 + 一行权限/收益说明」需要更宽的行宽。
        case .players: return 254
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
        // 播放器兼容：摘要两行 + 入口按钮（0 个第三方已开启）= 74。
        // 子态随列表行增长，由 `PageMetrics.playersContentHeight(enabledCount:)` 按行算，不写死槽位。
        case .players:
            return PageMetrics.playersContentHeight(enabledCount: 0)
        }
    }

    /// 该页的形状尺寸（chrome + 内容 + 统一内边距，夹在上下限内）。
    var shapeSize: CGSize { PageMetrics.shapeSize(for: self) }
}

/// 首页四种内容版式（SPEC §9.2）。同页不同子态高度不同（§7.6），
/// 所以版式必须是一个显式状态，而不是「共用 56 槽位 + 垂直居中」。
enum HomeLayout: String, Equatable {
    case playing
    case presenceOnly
    case permissionDenied
    case empty

    /// 唯一判定顺序：视图分支与高度换算共用这一处，避免两处 if 链漂移。
    /// IOPM 状态压过授权引导（有状态可显示时不必优先劝授权），曲目压过状态。
    static func resolve(media: MediaSnapshot, permission: MediaPermission) -> HomeLayout {
        if media.isPresenceOnly { return .presenceOnly }
        if media.hasTrack { return .playing }
        if permission == .denied { return .permissionDenied }
        return .empty
    }
}

/// 首页文案表（SPEC §7.7.5）：**行数档位在这里声明**，运行时不得量行数回写高度。
///
/// 当前真实文案在规范宽度（空态 254 / 拒绝态 206）下都是单行档 → H 107 / 120。
/// 文案加长到放不下时，把对应档改成 2（C 15 → 30，H → 122）；`--render-baseline`
/// 的 text-fit 会同时核对「声明档位 == 实际渲染行数」。
enum HomeCopyTable {
    static let emptyText = "暂无播放，先在 Music 里放一首"
    static let deniedText = "允许控制音乐，去系统设置开启"
    static let presenceHint = "用键盘媒体键 ⏮ ⏯ ⏭ 控制"

    /// 单行 = 1，双行 = 2。只允许 1 或 2（3 行禁止，§7.7.7）。
    static let emptyLines = 1
    static let deniedLines = 1

    /// 空态说明块高：15 × 行数档（单行 15 / 双行 30）。
    static var emptyBlockHeight: CGFloat {
        DesignSystem.Typography.body.lineHeight * CGFloat(emptyLines)
    }

    /// 被拒行容器高：max(28, 15 × 行数档)（单行 28 / 双行 30）。
    static var deniedRowHeight: CGFloat {
        max(DesignSystem.Control.md, DesignSystem.Typography.body.lineHeight * CGFloat(deniedLines))
    }
}

/// 展开态尺寸的统一换算：内容尺寸 → 形状尺寸。
///
/// 规则：形状 = 固定骨架 + 内容自然尺寸 + 四边统一内边距，再夹在上下限之间。
/// 上下限只防两个极端（窄到放不下 Header/Tab、单页内容把面板撑爆），
/// 不再有「页面内容区最小高度」这种会把不同内容拉平的中间档。
enum PageMetrics {
    /// 展开态宽度阶梯。**决策 D2（2026-11-16，项目所有者拍板）：采纳宽度阶梯。**
    ///
    /// 这是**我方决定**，不是行业做法——取证结论是上游四家都没有宽度阶梯：
    /// 闭合宽全部由硬件派生，展开宽是几个孤立固定值（600 与闭合宽无倍数关系）。
    /// 采纳前提：接受「不许自由调宽」。新增页宽必须显式加进这张表，且仍是 `u` 的倍数。
    static let widthLadder: [CGFloat] = [228, 248, 300]

    /// 统一内边距，四边一致（复用间距阶梯的 lg = 16）。
    /// 视图层整块 `.padding(contentPadding)`，不再分别写 top/horizontal。
    /// **只用于竖向**；左右改由 `contentHorizontalInset(topTangentOffset:)` 驱动。
    static let contentPadding = DesignSystem.Spacing.lg

    /// 内容左右内缩：**由顶部切点偏移 t 驱动**（闭合 6 / 展开 19）+ 侧壁净间隙。
    ///
    /// 参照实现把 `top` 复用为内容左右内缩；我们保留一个明确的净间隙
    /// （`NotchHardware.contentGap` = 4pt），保证内容盒始终落在侧壁内侧、不贴壁。
    /// 旧实现固定 16，展开 t=19 时内容被侧壁裁掉 3pt（实测内容像素贴到侧壁）。
    static func contentHorizontalInset(topTangentOffset: CGFloat) -> CGFloat {
        topTangentOffset + NotchHardware.contentGap
    }

    /// 展开态左右内缩：19 + 4 = **23**。面板宽 = 内容宽 + 2×23（宽度不变，内容让位）。
    static var openContentHorizontalInset: CGFloat {
        contentHorizontalInset(topTangentOffset: ScreenGeometry.cornerRadiusInsets.opened.top)
    }

    /// 唯一一行 chrome 的高度：28pt（Tab 图标行，标题与状态文字都已删除）。
    static let chromeHeight = DesignSystem.Control.md
    /// chrome 行与内容区之间的间距（用间距而不是分隔线分组）。
    static let rowSpacing = DesignSystem.Spacing.md

    /// 顶部内边距：由 `NotchHardware.topInset(for:)` 从系统信号算出后注入，
    /// 视图与尺寸换算共用这一个值（默认等于统一内边距）。
    /// 有刘海时 = 硬件矩形下缘 + `contentGap`，让整块内容落到硬件之下。
    private(set) static var topInset = contentPadding

    static func configure(topInset value: CGFloat) {
        topInset = max(contentPadding, value)
    }

    /// 一页的高度预算：四个互不重叠的桶，相加正好等于面板高度。
    ///
    /// 旧的口径把 chrome 与底部 padding 也算进「内容区」，报出 80.6% 的同时又说
    /// chrome 占 19.4%，自相矛盾。这里拆成独立数字，分母都是面板总高。
    /// 系统让位单列：它是刘海硬件带挤出来的高度，不是设计留白，
    /// 否则有刘海的机器上「内容是不是最大的一块」会被硬件带直接判红。
    struct HeightBudget {
        /// 实际内容块高度（首页媒体行 / 文件架空状态框 / 计时器常驻行）。
        let content: CGFloat
        /// 唯一一行 chrome。
        let chrome: CGFloat
        /// 自有留白：四边内边距 + chrome 与内容之间的间距。
        let overhead: CGFloat
        /// 系统让位：顶部内边距超出统一内边距的部分（有刘海时 20，无刘海时 0）。
        let clearance: CGFloat

        var total: CGFloat { content + chrome + overhead + clearance }
        var contentRatio: Double { Double(content / total) }
        var chromeRatio: Double { Double(chrome / total) }
        var overheadRatio: Double { Double(overhead / total) }
        var clearanceRatio: Double { Double(clearance / total) }
    }

    static func heightBudget(
        for item: ExpandedItem,
        shelfCount: Int = 0,
        home: HomeLayout = .playing,
        playersEnabled: Int = 0
    ) -> HeightBudget {
        HeightBudget(
            content: contentHeight(for: item, shelfCount: shelfCount, home: home, playersEnabled: playersEnabled),
            chrome: chromeHeight,
            overhead: contentPadding * 2 + rowSpacing,
            clearance: max(0, topInset - contentPadding)
        )
    }

    /// 首页内容高：**只按 `HomeCopyTable` 的声明档位算**，不量行数（SPEC §7.7.5）。
    static func homeContentHeight(_ layout: HomeLayout) -> CGFloat {
        switch layout {
        case .playing:
            return DesignSystem.Size.cover            // 56 → H 148
        case .presenceOnly:
            return DesignSystem.Control.md            // 28 → H 120，恒单行
        case .permissionDenied:
            return HomeCopyTable.deniedRowHeight      // 28 / 30 → H 120 / 122
        case .empty:
            return HomeCopyTable.emptyBlockHeight     // 15 / 30 → H 107 / 122
        }
    }

    /// 设置页内容高（SPEC §8.5）：摘要两行 15+4+15 + 可选列表 + 12 + 入口按钮 28。
    ///
    /// 列表只在有已开启的第三方时出现：1 行 = 8+20，2 行 = 8+20+8+20（第 2 行折叠「另有 N 个」）。
    /// 于是 C = 74 / 102 / 130，H = 92 + C = **166 / 194 / 222**。
    static func playersContentHeight(enabledCount: Int) -> CGFloat {
        let rows = min(max(enabledCount, 0), 2)
        let list: CGFloat = rows == 0
            ? 0
            : DesignSystem.Spacing.sm
                + DesignSystem.Control.xs * CGFloat(rows)
                + DesignSystem.Spacing.sm * CGFloat(rows - 1)
        return DesignSystem.Typography.body.lineHeight * 2
            + DesignSystem.Spacing.xs
            + list
            + DesignSystem.Spacing.md
            + DesignSystem.Control.md
    }

    /// 内容高度：文件架按条目数、首页按版式、设置页按已开启个数；计时器取自然高度。
    /// 每个分支都只做「行高求和」，没有声明槽位、没有 Spacer、没有按比例分配。
    static func contentHeight(
        for item: ExpandedItem,
        shelfCount: Int = 0,
        home: HomeLayout = .playing,
        playersEnabled: Int = 0
    ) -> CGFloat {
        switch item {
        case .files:
            return FileShelfLayout.contentHeight(count: shelfCount)
        case .home:
            return homeContentHeight(home)
        case .players:
            return playersContentHeight(enabledCount: playersEnabled)
        case .timer:
            return item.contentHeight
        }
    }

    // MARK: - 内容份额下限

    /// 份额下限适用的内容高度门槛：内容 **≥ 60pt** 的页面才用 30% 口径。
    ///
    /// 低于 60pt 的页面，30% 反解出的高度不足一个控件档位，继续加高只会放大留白。
    /// 这类页面改用「固定开销不随内容增长」这条约束（见 `fixedOverhead`）：
    /// 断言真实总高 == 内容 + 固定开销，多压一分或者多留一分都会红。
    static let ratioFloorContentHeight: CGFloat = 60

    /// 内容块占面板高度的下限：**30%**，只对内容 ≥ 60pt 的页面生效。
    static let minContentRatio: Double = 0.30

    /// 固定开销：顶部内边距 + chrome + 行间距 + 底部内边距。
    /// 有刘海时 = 36 + 28 + 12 + 16 = **92**，不随内容变化。
    static var fixedOverhead: CGFloat {
        topInset + chromeHeight + rowSpacing + contentPadding
    }

    enum ContentShareRule {
        /// 内容 ≥ 60pt：份额必须 ≥ 30%。
        case ratioFloor
        /// 内容 < 60pt：30% 不适用，改判「总高 = 内容 + 固定开销」。
        case fixedOverhead
    }

    struct ContentShareVerdict {
        let rule: ContentShareRule
        let content: CGFloat
        let total: CGFloat
        let overhead: CGFloat

        var ratio: Double { total > 0 ? content / total : 0 }
        /// 30% 这一问的真实答案。固定开销口径下也照实输出，不做掩盖。
        var meetsRatioFloor: Bool { ratio >= minContentRatio }
        /// 固定开销是否一分没涨：总高 − 内容 == 固定开销。
        var overheadIsFixed: Bool { abs(total - content - overhead) < 0.01 }

        var passes: Bool {
            switch rule {
            case .ratioFloor: return meetsRatioFloor
            case .fixedOverhead: return overheadIsFixed
            }
        }
    }

    static func contentShareVerdict(
        for item: ExpandedItem,
        shelfCount: Int = 0,
        home: HomeLayout = .playing,
        playersEnabled: Int = 0
    ) -> ContentShareVerdict {
        let budget = heightBudget(for: item, shelfCount: shelfCount, home: home, playersEnabled: playersEnabled)
        return ContentShareVerdict(
            rule: budget.content >= ratioFloorContentHeight ? .ratioFloor : .fixedOverhead,
            content: budget.content,
            total: shapeSize(for: item, shelfCount: shelfCount, home: home, playersEnabled: playersEnabled).height,
            overhead: fixedOverhead
        )
    }

    /// 一行报告：达标就写「≥ 下限 30% 达标」，不达标就写「< 下限 30% 不达标」，
    /// 固定开销口径再追加真实拆解（总高 = 内容 + 固定开销）。
    static func contentShareReport(for item: ExpandedItem, shelfCount: Int = 0) -> String {
        let verdict = contentShareVerdict(for: item, shelfCount: shelfCount)
        let label = item == .files ? "文件架 \(shelfCount) 个" : item.title
        let head = String(
            format: "%@ 内容 %.1f%% (%d/%d)",
            label, verdict.ratio * 100, Int(verdict.content), Int(verdict.total)
        )
        let floor = String(
            format: "%@ 下限 %d%% %@",
            verdict.meetsRatioFloor ? "≥" : "<",
            Int(minContentRatio * 100),
            verdict.meetsRatioFloor ? "达标" : "不达标"
        )
        switch verdict.rule {
        case .ratioFloor:
            return "\(head) \(floor)"
        case .fixedOverhead:
            let breakdown = String(
                format: "；内容 < %dpt，改判固定开销 %.0fpt：总高 %.0f = %.0f + %.0f %@",
                Int(ratioFloorContentHeight), verdict.overhead,
                verdict.total, verdict.content, verdict.overhead,
                verdict.overheadIsFixed ? "达标" : "不达标"
            )
            return "\(head) \(floor)\(breakdown)"
        }
    }

    /// 下限：高度至少要放得下 chrome 行 + 间距 + 顶部/底部内边距（内容高度可以为 0）。
    static var minSize: CGSize {
        CGSize(
            width: 200,
            height: topInset + chromeHeight + rowSpacing + contentPadding
        )
    }
    /// 上限：单页内容过大时的封顶值，保证窗口不会被一页撑爆。
    ///
    /// **232pt** = 文件架「3 整行 112 + 第 4 行露出 20pt」的视口 140 + 固定开销 92。
    /// 定稿口径（不再有 DEV-TEMP）：232 就是真实需求，244 会多出 12pt 纯留白
    /// （拆解后 244 的 +32 里有 16pt 与已有顶部内边距重复、12pt 是行间距重复）。
    static let maxSize = CGSize(width: 640, height: 232)

    static func shapeSize(
        for item: ExpandedItem,
        shelfCount: Int = 0,
        home: HomeLayout = .playing,
        playersEnabled: Int = 0
    ) -> CGSize {
        let content = item.contentSize
        return CGSize(
            width: min(max(content.width + openContentHorizontalInset * 2, minSize.width), maxSize.width),
            height: min(
                max(
                    contentHeight(for: item, shelfCount: shelfCount, home: home, playersEnabled: playersEnabled)
                        + chromeHeight + rowSpacing + topInset + contentPadding,
                    minSize.height
                ),
                maxSize.height
            )
        )
    }

    /// 所有页面里最大的形状尺寸：窗口按它固定，切页只改内容不改窗口。
    /// 文件架按溢出态（4 条）计算，否则窗口会被一屏之外的内容裁掉；
    /// 其余页取子态最高档（首页播放中 56、设置页 2 个已开启 130）。
    static var maxShapeSize: CGSize {
        ExpandedItem.allCases.reduce(CGSize.zero) { partial, item in
            let shelf = item == .files ? overflowShelfCount : 0
            let size = shapeSize(for: item, shelfCount: shelf, home: .playing, playersEnabled: 2)
            return CGSize(width: max(partial.width, size.width), height: max(partial.height, size.height))
        }
    }

    /// 溢出态条目数：一屏 3 条，第 4 条触发滚动。
    static var overflowShelfCount: Int { FileShelfLayout.visibleRows + 1 }
}
