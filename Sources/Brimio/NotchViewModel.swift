import AppKit
import SwiftUI
import Combine

/// 窗口侧状态机：只有 closed / open 两态，所有过渡交给 SwiftUI 插值。
@MainActor
final class NotchViewModel: ObservableObject {
    enum State: Equatable {
        case closed
        case open
    }

    @Published private(set) var state: State = .closed

    /// 展开态当前页。和 `state` 一样是**派生视图的唯一来源**：
    /// `select` 只发布这一个属性，不碰 state、也不碰尺寸，
    /// 所以切页不会触发开合曲线，开合也不会顺手改路由。
    @Published private(set) var route: ExpandedItem = .home

    /// 当前曲目快照与授权状态：由 `MediaService` 推送，视图只读。
    @Published private(set) var media: MediaSnapshot = .none
    @Published private(set) var mediaPermission: MediaPermission = .unknown

    /// 播放器兼容开关的版本号：开关存在 `PlayerRegistry`（UserDefaults），
    /// 这里只负责发一次变更让设置页重新取值，不复制一份状态。
    @Published private(set) var playerSettingsVersion = 0

    /// 文件架条目：只有 URL 引用与只读元数据，退出即丢弃，不写盘。
    @Published private(set) var shelfItems: [ShelfItem] = []
    /// 外部文件正拖到刘海上：只驱动描边高亮，不参与尺寸预算。
    @Published private(set) var isFileDragTarget = false

    let closedSize: CGSize
    /// 菜单栏高度，用来算刘海下方的 chin。
    let menuBarHeight: CGFloat

    /// 当前内容尺寸。
    ///
    /// 这里**不存一份独立状态**，而是从 `state` + `route` 派生：
    /// 之前 `notchSize` 和 `state` 各是一次 `@Published` 变更，
    /// SwiftUI 会把它们拆成两次视图更新——第一次只看到“尺寸已经变成终值、状态还是 closed”，
    /// `.animation(value:)` 的触发值没变，尺寸变化就跳过了动画；等第二次 `state` 变化时尺寸已经是终值。
    /// 派生之后一次交互只产生一次变更（开合改 state、切页改 route），尺寸和触发值在同一个 transaction 里。
    ///
    /// 展开态尺寸随页面变化（`PageMetrics`：内容 + 统一内边距，再夹上下限），窗口 frame 不动。
    ///
    /// 闭合态在有播放会话时向右加宽一个缩略图位：刘海本体宽度不能动，
    /// 缩略图必须挂在刘海右侧才看得见（见 `closedBadgeExtraWidth`）。
    var notchSize: CGSize {
        if isOpen { return routeShapeSize }
        return CGSize(
            width: closedSize.width + closedBadgeExtraWidth,
            height: closedSize.height
        )
    }

    /// 当前页的面板尺寸：文件架的高度随条目数变化，其余页等价于 `item.shapeSize`。
    var routeShapeSize: CGSize {
        PageMetrics.shapeSize(for: route, shelfCount: shelfItems.count)
    }

    /// 当前页的内容高度（视图按它撑开页面容器）。
    var routeContentHeight: CGFloat {
        PageMetrics.contentHeight(for: route, shelfCount: shelfItems.count)
    }

    /// 闭合态缩略图位：有播放会话才占宽，没有则完全为 0（不占位）。
    var closedBadgeExtraWidth: CGFloat {
        showsClosedBadge ? DesignSystem.Size.closedBadge + DesignSystem.Spacing.sm : 0
    }

    /// 闭合态是否显示右侧徽标：有曲目（唯一能拿到元数据的通道），
    /// 或「只有状态」但确实是音乐类播放器。
    ///
    /// 为什么 presence-only 也要占位：183pt 的闭合形状约等于物理刘海宽度，
    /// 它的正中就是摄像头模组的实体遮挡区，文字画在那里等于画在硬件背后。
    /// 闭合态因此**不放任何文字**，只用右侧加宽槽位里的一枚 20×20 图标表达「谁在播」。
    ///
    /// 为什么要过滤音乐类：IOPM 只知道「有进程在出声」，网页视频、微信语音、游戏
    /// 都会命中；不过滤就会在刘海右边弹出浏览器/微信图标。这类会话只进展开态。
    var showsClosedBadge: Bool {
        guard !isOpen else { return false }
        if media.hasTrack { return true }
        return media.isPresenceOnly && media.isMusicPlayer
    }

    /// `notchSize` 是居中绘制的；加宽只应向右长，所以整体右移半个增量，
    /// 让刘海本体的左缘位置保持不变（否则缩略图会把整块往左推）。
    var closedBadgeOffset: CGFloat {
        closedBadgeExtraWidth / 2
    }

    /// 收到 `MediaService` 的推送。
    func applyMedia(_ snapshot: MediaSnapshot, permission: MediaPermission) {
        media = snapshot
        mediaPermission = permission
    }

    /// 播放器开关变更后由控制器调用：只发一次版本号，设置页重新读 `PlayerRegistry`。
    func reloadPlayerSettings() {
        playerSettingsVersion += 1
    }

    // MARK: - 文件架

    /// 拖入文件：先清掉失效引用（用户动作即检查点），再置顶去重。返回真正新增条数。
    @discardableResult
    func addShelfFiles(_ urls: [URL]) -> Int {
        _ = FileShelfStore.pruneMissing(&shelfItems)
        return FileShelfStore.add(urls, to: &shelfItems)
    }

    func removeShelfFile(_ item: ShelfItem) {
        FileShelfStore.remove(url: item.url, from: &shelfItems)
    }

    /// 清空只移除引用，不删文件。
    func clearShelf() {
        guard !shelfItems.isEmpty else { return }
        shelfItems.removeAll()
    }

    /// 用户动作时调用：返回被移除的失效文件名。
    @discardableResult
    func pruneShelf() -> [String] {
        FileShelfStore.pruneMissing(&shelfItems)
    }

    /// 拖出完成：move 之后原路径失效，条目必须立即消失。
    func applyShelfDragOut(_ url: URL, operation: NSDragOperation) {
        _ = FileShelfStore.applyDragOut(url: url, operation: operation, items: &shelfItems)
    }

    func setFileDragTarget(_ active: Bool) {
        isFileDragTarget = active
    }

    /// 开合各用一条曲线，但仍然是唯一动画源：
    /// 视图上只挂一个 `.animation(...)`，调用方不再包 `withAnimation`。
    /// `openAnimation = .spring(response: 0.42, dampingFraction: 0.8)`
    /// `closeAnimation = .spring(response: 0.45, dampingFraction: 1.0)`
    let openAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    let closeAnimation: Animation = .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    init(closedSize: CGSize, menuBarHeight: CGFloat = 0) {
        self.closedSize = closedSize
        self.menuBarHeight = menuBarHeight
    }

    var isOpen: Bool { state == .open }

    func open() {
        guard state == .closed else { return }
        // 展开是一次用户动作：顺手清掉失效引用，不挂定时器。
        if route == .files { pruneShelf() }
        state = .open
    }

    func close() {
        guard state == .open else { return }
        state = .closed
    }

    /// 切换分页：一次交互只发布一次变更（只改 `route`）。
    /// 不动 `state`、不动尺寸，尺寸由 `notchSize` 派生，切页时天然不变。
    func select(_ item: ExpandedItem) {
        guard route != item else { return }
        if item == .files { pruneShelf() }
        route = item
    }

    /// 唯一动画源用的曲线：开合各一条，切页发生在展开态，复用展开曲线。
    var currentAnimation: Animation {
        isOpen ? openAnimation : closeAnimation
    }

    /// 唯一动画源的触发值：尺寸 + 路由合在一起。
    ///
    /// 视图上只挂 **一个** `.animation(currentAnimation, value: animationTrigger)`：
    /// 开合只改尺寸、切页只改路由，两种情况都让同一个触发值变化，
    /// 因此只会有一个 transaction、一条曲线，不存在两处 `.animation` 互相覆盖。
    struct AnimationTrigger: Equatable {
        let size: CGSize
        let route: ExpandedItem
    }

    var animationTrigger: AnimationTrigger {
        AnimationTrigger(size: notchSize, route: route)
    }

    /// 顶部圆角：闭合 6，展开 0（方角）。
    ///
    /// 展开态取 0：面板的顶边就压在屏幕顶边上，任何正圆角（19pt 更明显）都会在屏幕顶边
    /// 与形状之间露出左右两个背景三角。改成方角后，顶边整条与屏幕顶边齐平。
    /// 闭合态仍用 6，与物理刘海下缘的弧度衔接。
    var topCornerRadius: CGFloat {
        isOpen ? 0 : ScreenGeometry.cornerRadiusInsets.closed.top
    }

    /// 底部圆角：闭合 14、展开 24。闭合高度只有 32，14 让两侧仍留直线段；
    /// 展开后 24 收口更圆，与顶部方角形成「上平下圆」。
    var bottomCornerRadius: CGFloat {
        isOpen ? ScreenGeometry.cornerRadiusInsets.opened.bottom : ScreenGeometry.cornerRadiusInsets.closed.bottom
    }

    /// 刘海和菜单栏底边之间的透明黑补块高度。
    /// 取 max(0, 菜单栏高 − 刘海高)：差值就是菜单栏底边与形状之间那条缝，
    /// 刘海高于菜单栏时也不出负高度。
    var chinHeight: CGFloat {
        isOpen ? 0 : max(0, menuBarHeight - closedSize.height)
    }

    /// chin 宽度取闭合刘海宽度：补块两侧不超出刘海本体。
    var chinWidth: CGFloat { closedSize.width }
}
