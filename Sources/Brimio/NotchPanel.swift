import AppKit
import SwiftUI

/// 宿主视图：强制清空 safeAreaInsets。
/// 窗口顶部压在菜单栏/刘海区域时，系统会给 contentView 一个 32pt 左右的上边距，
/// SwiftUI 内容会整体下移，表现就是「形状浮在下面、顶部空一条」。
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// 刘海面板：无边框、非激活、置顶、透明。
/// 关键点：不抢 key/main，所以点它不会中断当前 App 的输入焦点。
final class NotchPanel: NSPanel {
    init(contentRect: NSRect, contentView: NSView) {
        super.init(
            contentRect: contentRect,
            // 窗口层：nonactivatingPanel + utilityWindow + hudWindow 让面板不抢 key/main，
            // 点它不会中断当前 App 的输入焦点。
            // `.borderless` 的 rawValue 是 0，写不写都是 no-op（没有 .titled 就本来没有标题栏），
            // 保留是为了把「无标题栏」显式写进 styleMask，读代码时不必再推。
            // 之前那次「简化」之所以没破坏表现：窗口 isOpaque=false、backgroundColor=.clear、
            // hasShadow=false，而这三个 flag 只影响标准窗口外观（标题栏/工具条纹理），
            // 在无 .titled 且整窗透明的组合下本来就画不出来，所以视觉上无差别。
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false

        // 高于菜单栏，覆盖普通窗口；配合 canJoinAllSpaces 出现在所有桌面。
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]

        self.contentView = contentView

        // 初始为闭合态：整窗穿透，避免 640×210 的透明区域吃掉菜单栏/桌面点击。
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显式点击穿透开关：指针在可交互矩形内才接收事件。
    func setInteractive(_ interactive: Bool) {
        let shouldIgnore = !interactive
        guard ignoresMouseEvents != shouldIgnore else { return }
        ignoresMouseEvents = shouldIgnore
        NSLog("[Brimio] interactive=%d ignoresMouseEvents=%d", interactive ? 1 : 0, shouldIgnore ? 1 : 0)
    }
}
