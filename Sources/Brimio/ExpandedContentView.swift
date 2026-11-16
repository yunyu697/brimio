import SwiftUI

/// 授权引导行的 hover 状态：`@State` 依赖 SwiftUI 宏，本仓库的 SwiftPM 工具链插件
/// 在这台机器上不可用；与 `ShelfHoverState` 同口径用 `ObservableObject`。
@MainActor
final class GuideHoverState: ObservableObject {
    @Published var isHovered = false
}

/// 设置页列表图标的**测试夹具**：`nil` 时走生产路径（本机真实 app 图标）。
///
/// 基线/离屏渲染注入一个固定符号（见 `main.swift` 的 `--render-baseline` / `--render`），
/// 目的是让参考图跨机器可复现——真实图标取决于「这台机器装没装那个 app」。
/// 夹具只替换**画什么图**，不替换 16pt 尺寸、8pt 间距和 23 内容盒列位置，
/// 所以列布局、行高、文字宽度这些会出问题的量仍然由像素和 text-fit 看着；
/// 真实图标路径本身不涉及几何，退化分支（未安装）也用同一个 16pt 框。
enum PlayerIconFixture {
    /// 夹具符号名（SF Symbol）；nil = 生产路径。
    static var symbolName: String?
    /// 夹具使用的固定占位符号。
    static let baselineSymbol = "app.fill"
}

/// 展开态的内容骨架：唯一一行 chrome（Tab 图标，28pt）→ 页面容器。
///
/// 加一个页面只动 `ExpandedItem`（加 case / 图标 / 尺寸）和 `page(for:)`（加分支），
/// chrome 行由 `allCases` 生成、页面容器按 `route` 选可见页，这一层的结构不变。
/// 样式全部来自 `DesignSystem`，这里不写裸字号/间距/颜色。
///
/// 信息分级见 `DESIGN.md`：chrome 行只放导航控件，不放任何信息；
/// 首页常驻信息只有曲名与副信息两条。
struct ExpandedContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// 切页回调：交给窗口状态机的 `select(_:)`，一次交互只发布一次变更。
    let onSelect: (ExpandedItem) -> Void
    /// 播放控制回调：视图只发意图，由 `MediaService` 执行 AppleScript。
    let onMediaControl: (MediaControl) -> Void
    /// 播放器兼容：面板里只放摘要和入口，详细开关在独立设置窗口。
    let onOpenPlayerSettings: () -> Void
    /// 文件架条目拖出结束（最终 operation 由 AppKit 会话给出）。
    let onDragOutFile: (URL, NSDragOperation) -> Void
    /// 授权引导行是否悬停：只驱动 hover 底色，不参与尺寸。
    @StateObject private var guideHover = GuideHoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            chrome
            pages
        }
        // 四边用同一组 padding token：整块内容左对齐到同一条竖线，
        // 底部也留同样的一档，不再让不同页面把剩余高度撑成不同留白。
        // 顶部取 `PageMetrics.topInset`：有刘海时它是「硬件矩形下缘 + contentGap」，
        // 也就是展开态唯一的一条竖向让位规则（不按页特判），
        // 让 chrome 行与整页内容一起落到硬件矩形之下。
        // 左右取 `vm.contentHorizontalInset`：= 顶部切点偏移 t + 4pt 净间隙（闭合 10 / 展开 23），
        // 内容盒因此始终在侧壁内侧，不再是固定 16（展开 t=19 时会被裁 3pt）。
        .padding(.top, PageMetrics.topInset)
        .padding(.horizontal, vm.contentHorizontalInset)
        .padding(.bottom, DesignSystem.Spacing.lg)
        .foregroundStyle(DesignSystem.Colors.textPrimary)
    }

    // MARK: - 唯一一行 chrome

    /// 28pt 一行：三个图标 Tab，左侧排开。
    /// 没有应用名、没有状态文字、没有分隔线；选中态是色块，不是下划线。
    /// 命中区间隙用 xs(4pt)：28pt 命中区已经自带 4pt 透明扩边，
    /// 视觉上相邻选中块之间是 4 + 4 + 4 = 12pt，和改版前一致，且命中区互不重叠。
    private var chrome: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(ExpandedItem.allCases) { item in
                tab(item)
            }
            Spacer(minLength: DesignSystem.Spacing.none)
            clearShelfButton
        }
        .frame(height: DesignSystem.Control.md)
    }

    /// 清空按钮挂在 chrome 行最右（28pt 同一行），不新增行、不占内容预算。
    /// 空架时隐藏但保留占位：直接移除会让 Tab 行宽度随条目变化而回流。
    private var clearShelfButton: some View {
        let canClear = vm.route == .files && !vm.shelfItems.isEmpty
        return Button {
            vm.clearShelf()
        } label: {
            Image(systemName: "trash")
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: DesignSystem.Control.md, height: DesignSystem.Control.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canClear)
        .opacity(canClear ? 1 : 0)
        .allowsHitTesting(canClear)
        .accessibilityLabel("清空文件架")
    }

    private func tab(_ item: ExpandedItem) -> some View {
        let isSelected = vm.route == item
        return Button {
            onSelect(item)
        } label: {
            Image(systemName: item.iconName)
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
                // 视觉块 20pt：选中色块的尺寸，不跟着命中区一起放大。
                .frame(width: DesignSystem.Control.xs, height: DesignSystem.Control.xs)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                        .fill(DesignSystem.Colors.badgeFill)
                        // 选中块常驻，用 opacity 切换：结构稳定，
                        // 变化由外层唯一的 `.animation` 驱动，不需要第二处动画源。
                        .opacity(isSelected ? 1 : 0)
                )
                // 命中区 28pt（= chrome 行高）：图标与色块都不变大，
                // 只靠这层透明扩边把可点范围从 20 提到 28，满足最小点击目标。
                .frame(width: DesignSystem.Control.md, height: DesignSystem.Control.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 图标化之后文字不上屏，只留给 VoiceOver。
        .accessibilityLabel(item.title)
    }

    // MARK: - 页面容器

    /// 三页常驻、按 `route` 切 opacity，和根视图「黑底常驻 + 内容叠 opacity」同一套做法：
    /// 结构稳定，切页不会重建子树，也不会引入第二条动画曲线。
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ExpandedItem.allCases) { item in
                page(for: item)
                    .opacity(vm.route == item ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // 容器高度取当前页内容的自然高度：不额外垫高，
        // 底部内边距才恒等于 contentPadding；不可见页虽然尺寸不同，
        // 但 opacity 为 0 且被外层形状裁掉，不参与视觉布局。
        .frame(height: vm.routeContentHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func page(for item: ExpandedItem) -> some View {
        switch item {
        case .home:
            homePage
        case .files:
            filesPage
        case .timer:
            timerPage
        case .players:
            playersPage
        }
    }

    // MARK: - 首页（媒体页）

    /// 四种版式高度不同（SPEC §7.2 / §9.2）：播放中 56 → H148；只有状态 28 → H120；
    /// 拒绝授权 28 → H120；空态 15 → H107。版式判定只在 `HomeLayout.resolve` 一处，
    /// 这里只做分支，不重复优先级。
    @ViewBuilder
    private var homePage: some View {
        switch vm.homeLayout {
        case .presenceOnly:
            presenceRow
        case .playing:
            mediaRow
        case .permissionDenied:
            automationGuide
        case .empty:
            emptyMedia
        }
    }

    /// IOPM 通道：知道「谁在播」，但拿不到曲目。不编造曲名，也不放假控制按钮，
    /// 只说明这行状态和去哪里控制。
    ///
    /// 宽度不足时**整块隐藏右侧提示**（SPEC §7.7.4），主文字保持 1 行尾部截断；
    /// 不缩字号、不换行、不出现省略号掩盖状态。
    private var presenceRow: some View {
        ViewThatFits(in: .horizontal) {
            presenceLine(showHint: true)
            presenceLine(showHint: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignSystem.Control.md)
    }

    private func presenceLine(showHint: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("\(vm.media.appName) · 正在播放")
                .lineLimit(1)
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            if showHint {
                Spacer(minLength: DesignSystem.Spacing.sm)
                Text(HomeCopyTable.presenceHint)
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
    }

    /// 一行媒体信息：左封面、中曲名/副信息、右控制按钮。
    /// 常驻信息只有曲名与副信息两条；播放状态不写字，用图标表达。
    private var mediaRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            cover
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(vm.media.title)
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            // 文字列吃满中间剩余宽度，把控制按钮推到右侧；
            // 不再用独立 Spacer，少一处 12pt 间隙（HStack 的 spacing 会算在每两个子视图之间）。
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignSystem.Size.cover)
    }

    /// 副信息：歌手 · 专辑，空字段自动省略。
    private var subtitle: String {
        [vm.media.artist, vm.media.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 封面：读得到就显示真实图，读不到退化为音符占位。
    @ViewBuilder
    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous)
        if let data = vm.media.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: DesignSystem.Size.cover, height: DesignSystem.Size.cover)
                .clipShape(shape)
        } else {
            shape
                .fill(DesignSystem.Colors.badgeFill)
                .frame(width: DesignSystem.Size.cover, height: DesignSystem.Size.cover)
                .overlay {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .frame(width: DesignSystem.Size.coverGlyph, height: DesignSystem.Size.coverGlyph)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
        }
    }

    /// 授权被拒：不能空白、不能反复弹窗，给一行能直接跳到系统设置的引导。
    /// 行容器高 = max(28, 15 × 声明行数)，单行档 28 → H120；整行可点，hover 白 6%。
    private var automationGuide: some View {
        Button {
            openAutomationSettings()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "hand.raised.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(HomeCopyTable.deniedText)
                    .lineLimit(HomeCopyTable.deniedLines)
                    .textStyle(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HomeCopyTable.deniedRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                .fill(DesignSystem.Colors.hoverFill)
                .opacity(guideHover.isHovered ? 1 : 0)
        )
        .onHover { guideHover.isHovered = $0 }
    }

    /// 已授权但没在播放：空态说明（属于空态文案，不是常驻状态标签）。
    /// 高度 = 15 × 声明行数（单行 15 → H107），行数档位只在 `HomeCopyTable` 里声明。
    private var emptyMedia: some View {
        Text(HomeCopyTable.emptyText)
            .lineLimit(HomeCopyTable.emptyLines)
            .textStyle(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HomeCopyTable.emptyBlockHeight)
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private var controls: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            controlButton("backward.fill", .previous)
            playButton
            controlButton("forward.fill", .next)
        }
        .frame(height: DesignSystem.Control.md)
    }

    private func controlButton(_ symbol: String, _ control: MediaControl) -> some View {
        Button { onMediaControl(control) } label: {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: DesignSystem.Control.sm, height: DesignSystem.Control.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        Button { onMediaControl(.playPause) } label: {
            Image(systemName: vm.media.isPlaying ? "pause.fill" : "play.fill")
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.surface)
                .frame(width: DesignSystem.Control.md, height: DesignSystem.Control.md)
                .background(Circle().fill(DesignSystem.Colors.textPrimary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 文件架 / 计时器

    /// 文件架：空态虚线框，或有文件时的一屏三行（第 4 行起滚动）。
    /// 条目只是 URL 引用，视图层不读内容、不生成缩略图。
    private var filesPage: some View {
        FileShelfView(
            items: vm.shelfItems,
            onRemove: { item in vm.removeShelfFile(item) },
            onDragOut: onDragOutFile,
            dropLocation: vm.fileDropLocation
        )
    }

    private var timerPage: some View {
        Text("占位：计时器后续接入。")
            .textLineBox(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 设置页（SPEC §8.5）：摘要两行 → 已开启的第三方（0/1/2 行）→ 入口按钮。
    /// 内容高只按实际渲染的行高求和：34 + 列表(0 / 28 / 56) + 12 + 28 → 74 / 102 / 130。
    /// 入口按钮是「整行持久填充面」，左右再内缩 4（E7）：254 → 246，x = 23 + 4 = 27。
    private var playersPage: some View {
        // 读一次版本号，开关变化后这一页跟着重算。
        let version = vm.playerSettingsVersion
        let thirdParty = PlayerRegistry.entries.filter(\.isThirdParty)
        let enabled = thirdParty.filter { PlayerRegistry.isEnabled($0.bundleID) }
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.none) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("系统播放器：Music、Spotify（恒开）")
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("第三方 \(enabled.count)/\(thirdParty.count) 已开启 · 默认关闭")
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(enabled.isEmpty
                        ? DesignSystem.Colors.textTertiary
                        : DesignSystem.Colors.textSecondary)
            }
            if !enabled.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    playerRow(enabled[0])
                    if enabled.count >= 2 {
                        if enabled.count > 2 {
                            morePlayersRow(count: enabled.count - 1)
                        } else {
                            playerRow(enabled[1])
                        }
                    }
                }
                .padding(.top, DesignSystem.Spacing.sm)
            }
            Button(action: onOpenPlayerSettings) {
                Text("打开播放器设置…")
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignSystem.Control.md)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .fill(DesignSystem.Colors.badgeFill)
            )
            // E7 豁免：持久填充面再内缩 4，填充块落在 27…273。
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.top, DesignSystem.Spacing.md)
            .accessibilityLabel("打开播放器兼容设置")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: version) { _ in }
    }

    /// 列表行：图标 16 @ x23、间隙 8、名称 @ x47，行高 20。
    private func playerRow(_ entry: PlayerEntry) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            playerIcon(entry)
            Text(entry.name)
                .lineLimit(1)
                .textStyle(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer(minLength: DesignSystem.Spacing.none)
        }
        .frame(height: DesignSystem.Control.xs)
    }

    /// ≥3 个已开启：第 2 行折叠为「另有 N 个已开启」，不增高。
    private func morePlayersRow(count: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "ellipsis")
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("另有 \(count) 个已开启")
                .lineLimit(1)
                .textStyle(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Spacer(minLength: DesignSystem.Spacing.none)
        }
        .frame(height: DesignSystem.Control.xs)
    }

    /// 播放器图标：装了就取真实 app 图标，没装退化为同尺寸符号（尺寸口径一致）。
    @ViewBuilder
    private func playerIcon(_ entry: PlayerEntry) -> some View {
        if let symbol = PlayerIconFixture.symbolName {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }
}
