import SwiftUI

/// 刘海窗口的根视图：只负责画和命中，不含窗口逻辑。
///
/// 架构取舍：
/// - 外层固定 `ScreenGeometry.windowSize`（与窗口同大），内容通过 frame 在闭合/展开间插值；
/// - 内容在窗口内**顶对齐**，窗口多出的空间只用于画阴影和动画超调，不参与内容偏移；
/// - clipShape 只裁视觉，命中由 contentShape(Rectangle()) 决定；
/// - 动画只由 `.animation(...)` 驱动一处（开/收各一条曲线）。
struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    let onTap: () -> Void
    /// 切页回调：由窗口控制器转给 `vm.select(_:)`，一次交互只发布一次变更。
    let onSelect: (ExpandedItem) -> Void
    /// 播放控制回调：视图只发意图，由 `MediaService` 执行脚本。
    let onMediaControl: (MediaControl) -> Void
    /// 播放器兼容：打开独立设置窗口（面板高度放不下 7 个播放器的完整说明）。
    let onOpenPlayerSettings: () -> Void
    /// 文件拖到刘海上松手：交给窗口控制器加进文件架并切到文件架页。
    let onDropFiles: ([URL]) -> Void

    var body: some View {
        // 顶对齐：VStack(spacing: 0) + frame(maxHeight: windowSize.height, alignment: .top)，
        // 窗口高度比形状多出的 20pt（阴影余量）全部落在底部，顶部不产生空隙。
        VStack(spacing: DesignSystem.Spacing.none) {
            content
                .frame(width: vm.notchSize.width, height: vm.notchSize.height)
                // 自测用采样器：把尺寸包进 Animatable，SwiftUI 每插值一帧就会调一次
                // animatableData 的 setter，于是能拿到真实的中间尺寸序列（--animate-probe）。
                // 注意：必须放在 `.animation` 之前，也就是它的子树内；
                // 放在 `.animation` 之后就不在这个动画事务里，采不到中间值（之前踩过）。
                // 也不能用 GeometryReader 采样：frame 动画在渲染层插值，GeometryReader 不会逐帧回调。
                // 整个采样设施只在 DEBUG 构建存在（Release 下这个 modifier 是空的）。
                .modifier(DebugSizeProbe(size: vm.notchSize))
                .background(DesignSystem.Colors.surface)
                .clipShape(
                    NotchShape(
                        topCornerRadius: vm.topCornerRadius,
                        bottomCornerRadius: vm.bottomCornerRadius
                    )
                )
                // 顶部 1pt 补线：
                // 在两侧顶部圆角之间补一条黑线，避免顶边和屏幕边缘之间出现发丝缝。
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(DesignSystem.Colors.surface)
                        .frame(height: DesignSystem.Size.hairline)
                        .padding(.horizontal, vm.topCornerRadius)
                }
                // 方向性阴影：顶部完全不投影，只在下方与两侧下缘出现。
                // 若用一圈均匀投影（`.shadow(0.7, radius: 6)`），贴顶的面板左右会留下
                // 从 y=0 开始的竖向暗带（实测 82.7/255），看起来像浮在屏幕上的卡片。
                .background { shadowLayer }
                // 缩略图只向右长：形状整体右移半个增量，让刘海本体左缘不动。
                // 展开时增量归 0，位移随开合一起插值。
                .offset(x: vm.closedBadgeOffset)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                // 外部文件拖到刘海上：闭合态也要能接（拖动期间窗口被临时设为可交互）。
                .onDrop(of: [.fileURL], delegate: FileDropDelegate(onFiles: onDropFiles))
                // 拖动经过时给形状描一圈亮边：不加宽、不出文字，不改变任何尺寸。
                .overlay {
                    if vm.isFileDragTarget {
                        NotchShape(
                            topCornerRadius: vm.topCornerRadius,
                            bottomCornerRadius: vm.bottomCornerRadius
                        )
                        .stroke(DesignSystem.Colors.textSecondary, lineWidth: DesignSystem.Size.hairline)
                    }
                }
                // 唯一动画源：放在这一层最后，覆盖上面整条子树（frame 尺寸、clipShape 的
                // 顶部/底部圆角、shadow 不透明度、分页内容的 opacity）——这些都是 Animatable，
                // 会一起逐帧插值。
                // 触发值是 `animationTrigger`（尺寸 + 路由的组合）：
                // 开合只改 state（尺寸变）、切页只改 route，两者都让同一个触发值变化，
                // 于是只有一个 transaction、一条曲线，不存在两处 `.animation` 互相覆盖。
                .animation(vm.currentAnimation, value: vm.animationTrigger)

            // 刘海下方的 chin：高度 = 菜单栏高 - 刘海高（刘海通常比菜单栏矮，差值就是那条缝），
            // 用 0.01 透明度的黑矩形补齐，避免菜单栏底边和形状之间露缝。
            if vm.chinHeight > 0 {
                Rectangle()
                    .fill(DesignSystem.Colors.surfaceVeil)
                    .frame(width: vm.chinWidth, height: vm.chinHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 窗口压在菜单栏/刘海区域时，NSHostingView 会带 safeAreaInsets，
        // 不忽略的话内容整体下移 safeAreaInsets.top（本机 32pt），顶部直接空一条。
        .ignoresSafeArea()
        // 全视图只有内容链最后那一处 .animation（唯一动画源），外层不再重复挂；
        // 这里只负责顶对齐，不参与尺寸插值。
        .preferredColorScheme(.dark)
    }

    /// 方向性阴影层：把形状自身当作投影源，先用竖向渐变遮掉顶部一段再发散。
    ///
    /// 为什么要这么做：`.shadow` 是四周均匀的，面板贴着屏幕顶边时会把阴影也往 y<0 和
    /// 两侧上方渗，形成「浮在屏幕上的卡片」观感。遮罩 alpha=0 的区域不产生阴影，
    /// 所以顶部 25% 高度天然不投影，只有下方与两侧下缘有。
    private var shadowLayer: some View {
        NotchShape(
            topCornerRadius: vm.topCornerRadius,
            bottomCornerRadius: vm.bottomCornerRadius
        )
        .fill(DesignSystem.Colors.surface)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: DesignSystem.Effects.panelShadowMaskClear,
                          location: DesignSystem.Effects.panelShadowFadeStart),
                    .init(color: DesignSystem.Effects.panelShadowMaskOpaque,
                          location: DesignSystem.Effects.panelShadowFadeEnd)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .shadow(
            color: DesignSystem.Colors.surface.opacity(
                vm.isOpen
                    ? DesignSystem.Effects.panelShadowOpacityOpen
                    : DesignSystem.Effects.panelShadowOpacityClosed
            ),
            radius: DesignSystem.Effects.panelShadowRadius,
            x: 0,
            y: DesignSystem.Effects.panelShadowOffsetY
        )
    }

    private var content: some View {
        // 结构必须稳定：不能用 `if vm.isOpen { A } else { B }` 切换类型。
        // 类型一换 SwiftUI 就当成「移除 + 插入」，动画期间会同时存在两份各自插值的副本
        // （采样序列会交出错乱的两条曲线），闭合态的黑底也会跟着重建。
        // 这里固定一层 ZStack：黑底常驻，展开的文字用 opacity 叠加。
        ZStack(alignment: .topLeading) {
            DesignSystem.Colors.surface
            ExpandedContentView(
                vm: vm,
                onSelect: onSelect,
                onMediaControl: onMediaControl,
                onOpenPlayerSettings: onOpenPlayerSettings
            )
            .opacity(vm.isOpen ? 1 : 0)
            // 闭合态徽标：挂在刘海右侧的加宽位里，展开时淡出。
            // 这一层（闭合挡）**不允许出现任何文字**：183pt 的闭合形状正中就是摄像头模组的
            // 实体遮挡区，文字画在那儿等于画在硬件背后。presence-only 用播放器图标表达。
            ClosedMediaBadge(media: vm.media)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, DesignSystem.Spacing.sm)
                .opacity(vm.showsClosedBadge ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

/// 仅用于 `--animate-probe`：按帧记录 SwiftUI 实际插值出的尺寸与圆角。
///
/// 整段采样设施都关在 `#if DEBUG` 里：
/// - Release 构建没有这些类型，`NotchShape.animatableData` 里也没有记录调用，
///   逐帧插值时不会产生任何额外内存写入；
/// - Debug 构建下还要 `isEnabled` 为真（只有 `--animate-probe` 会打开）才真正记录。
#if DEBUG
enum NotchLayoutProbe {
    static var isEnabled = false
    static var samples: [(time: TimeInterval, size: CGSize)] = []
    static var shapeSamples: [(time: TimeInterval, top: CGFloat, bottom: CGFloat)] = []

    static func reset() {
        samples.removeAll()
        shapeSamples.removeAll()
    }

    static func record(_ size: CGSize) {
        guard isEnabled else { return }
        samples.append((ProcessInfo.processInfo.systemUptime, size))
    }

    static func recordShape(top: CGFloat, bottom: CGFloat) {
        guard isEnabled else { return }
        shapeSamples.append((ProcessInfo.processInfo.systemUptime, top, bottom))
    }
}

/// 把尺寸包装成 `Animatable`：SwiftUI 每插值一帧会调用 `animatableData` 的 setter，
/// 这里顺手记录，用来证明开合过程中存在中间尺寸。
struct SizeProbe: View, Animatable {
    var size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(size.width, size.height) }
        set {
            size = CGSize(width: newValue.first, height: newValue.second)
            NotchLayoutProbe.record(size)
        }
    }

    var body: some View {
        Color.clear
    }
}

/// DEBUG 下的采样装饰。
struct DebugSizeProbe: ViewModifier {
    let size: CGSize

    func body(content: Content) -> some View {
        content.background(SizeProbe(size: size))
    }
}
#else
/// Release 下是空修饰符，不引入任何额外视图节点。
struct DebugSizeProbe: ViewModifier {
    let size: CGSize

    func body(content: Content) -> some View {
        content
    }
}
#endif
