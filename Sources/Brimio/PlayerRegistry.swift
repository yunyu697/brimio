import Foundation

/// 一个播放器的兼容配置。分组决定默认开关与权限模型：
/// - `automation`（Music / Spotify）：默认开启，首次读取时由系统弹一次 Automation 授权，
///   权限一次性、明确指向该 App；
/// - `menuBar`（国产/第三方播放器）：**默认关闭**，必须由用户在设置里逐个开启。
///   未开启时不执行任何针对该 App 的读取，也不会触发任何权限请求。
struct PlayerEntry: Identifiable, Equatable {
    enum Channel: String {
        /// Apple Event（Automation 授权）。
        case automation
        /// 只读系统级播放状态（IOPM，零权限）。
        case menuBar
    }

    /// 真正会向系统发起的权限请求。只有 Automation 一种：AX 读曲名通道已暂停投入，
    /// 代码里没有任何 `AXUIElement` 调用，所以这个枚举里不允许出现「辅助功能」。
    enum Permission: String {
        case automation
    }

    let bundleID: String
    let name: String
    let channel: Channel
    /// 这个条目实际会触发的权限请求；空集合 = 不需要任何额外权限。
    /// 文案由它推导，避免「说明」和「行为」各写一份。
    let permissions: Set<Permission>
    /// 开启后能得到什么。
    let benefit: String
    /// 不开启会怎样。
    let disabledEffect: String

    var id: String { bundleID }
    var isThirdParty: Bool { channel == .menuBar }

    /// 给用户看的权限原话，从 `permissions` 推导。
    var permission: String {
        if permissions.isEmpty {
            return "不需要额外权限（只读系统级播放状态，不针对单个 App）"
        }
        return "Automation（首次使用时由系统弹窗，只针对 \(name)）"
    }
}

enum PlayerRegistry {
    static let entries: [PlayerEntry] = [
        PlayerEntry(
            bundleID: "com.apple.Music",
            name: "Music",
            channel: .automation,
            permissions: [.automation],
            benefit: "曲名、歌手、专辑、封面，可切歌",
            disabledEffect: "系统播放器默认开启；拒绝授权后只显示空态引导"
        ),
        PlayerEntry(
            bundleID: "com.spotify.client",
            name: "Spotify",
            channel: .automation,
            permissions: [.automation],
            benefit: "曲名、歌手、专辑、封面，可切歌",
            disabledEffect: "系统播放器默认开启；拒绝授权后只显示空态引导"
        ),
        PlayerEntry(
            bundleID: "com.netease.163music",
            name: "网易云音乐",
            channel: .menuBar,
            permissions: [],
            benefit: "显示播放状态；播放/切歌请用键盘媒体键",
            disabledEffect: "完全不读取、不显示，也不请求任何权限"
        ),
        PlayerEntry(
            bundleID: "com.tencent.QQMusic",
            name: "QQ 音乐",
            channel: .menuBar,
            permissions: [],
            benefit: "显示播放状态；播放/切歌请用键盘媒体键",
            disabledEffect: "完全不读取、不显示，也不请求任何权限"
        ),
        PlayerEntry(
            bundleID: "com.kugou.mac",
            name: "酷狗音乐",
            channel: .menuBar,
            permissions: [],
            benefit: "显示播放状态；播放/切歌请用键盘媒体键",
            disabledEffect: "完全不读取、不显示，也不请求任何权限"
        ),
        PlayerEntry(
            bundleID: "com.kuwo.KuwoMusic",
            name: "酷我音乐",
            channel: .menuBar,
            permissions: [],
            benefit: "显示播放状态；播放/切歌请用键盘媒体键",
            disabledEffect: "完全不读取、不显示，也不请求任何权限"
        ),
        PlayerEntry(
            bundleID: "com.google.YouTubeMusic",
            name: "YouTube Music",
            channel: .menuBar,
            permissions: [],
            benefit: "显示播放状态；播放/切歌请用键盘媒体键",
            disabledEffect: "完全不读取、不显示，也不请求任何权限"
        )
    ]

    static func entry(for bundleID: String) -> PlayerEntry? {
        entries.first { $0.bundleID == bundleID }
    }

    /// UserDefaults 键。自测需要重置到「默认关闭」时也用这一个，避免测试字典泄漏。
    static func defaultsKey(_ bundleID: String) -> String {
        "players.enabled.\(bundleID)"
    }

    /// 系统播放器恒为开启；第三方播放器看用户开关，默认关闭。
    static func isEnabled(_ bundleID: String) -> Bool {
        guard let entry = entry(for: bundleID) else { return false }
        if !entry.isThirdParty { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey(bundleID))
    }

    /// 只有第三方播放器可以切换；系统播放器不接受关闭（它们的权限由系统弹窗管理）。
    static func setEnabled(_ enabled: Bool, for bundleID: String) {
        guard let entry = entry(for: bundleID), entry.isThirdParty else { return }
        UserDefaults.standard.set(enabled, forKey: defaultsKey(bundleID))
    }

    /// 读取闸门：未开启的播放器既不读也不显示。
    static func allowsReading(_ bundleID: String) -> Bool {
        isEnabled(bundleID)
    }
}
