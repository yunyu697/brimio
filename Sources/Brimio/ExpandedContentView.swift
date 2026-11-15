import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            chrome
            pages
        }
        // 四边用同一组 padding token：整块内容左对齐到同一条竖线，
        // 底部也留同样的一档，不再让不同页面把剩余高度撑成不同留白。
        // 展开态顶部是方角（见 NotchViewModel.topCornerRadius），
        // 留 lg(16pt) 是为了避开首行图标贴住屏幕顶边/阴影，不是为圆角让位。
        .padding(DesignSystem.Spacing.lg)
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

    /// 四种状态共用同一个 268×56 的槽位，面板高度不因状态跳变：
    /// 只有 IOPM 状态 → 一行「App · 正在播放」+ 媒体键说明；有曲目 → 封面 + 曲名/副信息 + 控制；
    /// 拒绝授权 → 一行可点击的授权引导；什么都没有 → 空态说明。
    ///
    /// 顺序就是优先级：IOPM 状态压过授权引导（有状态可显示时不必优先劝授权），
    /// 曲目压过状态（元数据永远比「谁在播」信息量大）。
    @ViewBuilder
    private var homePage: some View {
        if vm.media.isPresenceOnly {
            presenceRow
        } else if vm.media.hasTrack {
            mediaRow
        } else if vm.mediaPermission == .denied {
            automationGuide
        } else {
            emptyMedia
        }
    }

    /// IOPM 通道：知道「谁在播」，但拿不到曲目。不编造曲名，也不放假控制按钮，
    /// 只说明这行状态和去哪里控制。
    private var presenceRow: some View {
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
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text("用键盘媒体键 ⏮ ⏯ ⏭ 控制")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignSystem.Size.cover)
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
                Text("允许控制音乐，去系统设置开启")
                    .lineLimit(1)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: DesignSystem.Spacing.none)
                Image(systemName: "chevron.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DesignSystem.Size.cover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 已授权但没在播放：空态说明（属于空态文案，不是常驻状态标签）。
    private var emptyMedia: some View {
        Text("暂无播放，先在 Music 里放一首")
            .lineLimit(1)
            .textLineBox(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DesignSystem.Size.cover)
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
        FileShelfView(items: vm.shelfItems) { item in
            vm.removeShelfFile(item)
        }
    }

    private var timerPage: some View {
        Text("占位：计时器后续接入。")
            .textLineBox(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playersPage: some View {
        // 读一次版本号，开关变化后这一页跟着重算。
        let version = vm.playerSettingsVersion
        let thirdParty = PlayerRegistry.entries.filter(\.isThirdParty)
        let enabledCount = thirdParty.filter { PlayerRegistry.isEnabled($0.bundleID) }.count
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("系统播放器：Music、Spotify（系统弹窗授权）")
                .lineLimit(1)
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("第三方播放器：\(enabledCount)/\(thirdParty.count) 已开启，默认关闭。")
                .lineLimit(1)
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Button(action: onOpenPlayerSettings) {
                Text("打开播放器设置…")
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: DesignSystem.Control.md)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .fill(DesignSystem.Colors.badgeFill)
            )
            .accessibilityLabel("打开播放器兼容设置")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: version) { _ in }
    }
}
