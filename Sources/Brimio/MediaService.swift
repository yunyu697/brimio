import AppKit
import Foundation

/// 播放器返回的最小快照。只带界面要用的字段，不存脚本原文。
struct MediaSnapshot: Equatable {
    enum Source: String, Equatable {
        case music
        case spotify
        /// 只有播放状态、没有元数据：来自 IOPM 断言（任意播放器都适用）。
        case audioProcess
    }

    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// 封面原始数据；Music 直接给图片字节，Spotify 需要再拉一次 URL。
    var artwork: Data?
    var source: Source
    /// `audioProcess` 时用来显示「App 名 · 正在播放」。
    var appName: String = ""
    var bundleID: String = ""
    /// 是否音乐类播放器。IOPM 只保证「有进程在出声」，闭合态徽标要再过滤一层。
    var isMusicPlayer: Bool = false

    /// 有没有“正在播放的曲目”。停止状态也保留曲目信息，但 `isPlaying == false`。
    var hasTrack: Bool { !title.isEmpty }
    /// 只有状态、没有曲目信息（IOPM 通道）。
    var isPresenceOnly: Bool { source == .audioProcess }

    /// 去重用的键：曲目变化才需要重拉封面。
    var trackKey: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    static let none = MediaSnapshot(
        title: "", artist: "", album: "",
        isPlaying: false, artwork: nil, source: .music
    )

    /// IOPM 通道的快照：只有「谁在播」，没有任何曲目字段。
    static func presence(bundleID: String, appName: String, isMusicPlayer: Bool) -> MediaSnapshot {
        MediaSnapshot(
            title: "", artist: "", album: "",
            isPlaying: true, artwork: nil, source: .audioProcess,
            appName: appName, bundleID: bundleID, isMusicPlayer: isMusicPlayer
        )
    }
}

/// Automation 授权状态。`unknown` 表示还没发过 Apple Event。
enum MediaPermission: Equatable {
    case unknown
    case granted
    case denied
}

/// 播放控制动作。视图只发意图，不碰脚本。
enum MediaControl {
    case playPause
    case next
    case previous
}

/// 媒体后端协议。AppleScript 是唯一实现；为什么没有 MediaRemote 探测，见 README「媒体通道实测结论」。
protocol MediaBackend {
    var name: String { get }
    /// 读当前状态。没有播放会话时返回 `.none`。
    func readSnapshot() throws -> MediaSnapshot
    /// 读取当前曲目封面；没有则返回 nil。
    func readArtwork() throws -> Data?
    func perform(_ control: MediaControl) throws
}

/// AppleScript（Automation）后端：主路径。
///
/// 只对**已经在运行**的播放器发 Apple Event：`tell application "Music" ...` 即使只是
/// `it is running` 也会把未启动的 App 拉起来，所以运行判定放在 NSWorkspace，不放进脚本。
final class AppleScriptBackend: MediaBackend {
    let name = "AppleScript"

    /// AppleScript 的字段分隔符：ASCII 31（单元分隔符），曲名里不会出现。
    private static let fieldSeparator = "\u{1F}"

    private var runningBundleID: String? {
        Self.bundlePriority.first { id in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        }
    }

    /// AppleScript 真正覆盖的 App，按优先级排列（Music 压过 Spotify）。
    private static let bundlePriority = ["com.apple.Music", "com.spotify.client"]

    /// 供 `--selftest` 校验：`PlayerRegistry` 里声明 Automation 的条目必须都在这个集合里，
    /// 否则就是「向用户写了权限、代码却不会发起」。
    static let supportedBundleIDs = Set(bundlePriority)

    private var source: MediaSnapshot.Source? {
        switch runningBundleID {
        case "com.apple.Music": return .music
        case "com.spotify.client": return .spotify
        default: return nil
        }
    }

    func readSnapshot() throws -> MediaSnapshot {
        guard let source else { return .none }
        let app = source == .music ? "Music" : "Spotify"
        let script = """
        tell application "\(app)"
            set ps to (player state as text)
            if ps is "stopped" then return "stopped"
            set t to current track
            return ps & (ASCII character 31) & (name of t) & (ASCII character 31) & (artist of t) & (ASCII character 31) & (album of t)
        end tell
        """
        let output = try execute(script)
        guard output != "stopped" else {
            return MediaSnapshot(
                title: "", artist: "", album: "",
                isPlaying: false, artwork: nil, source: source
            )
        }
        let parts = output.components(separatedBy: Self.fieldSeparator)
        guard parts.count >= 4 else { return .none }
        return MediaSnapshot(
            title: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
            artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            isPlaying: parts[0].contains("playing"),
            artwork: nil,
            source: source
        )
    }

    func readArtwork() throws -> Data? {
        switch source {
        case .music:
            let script = """
            tell application "Music"
                try
                    return data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
            """
            return try executeData(script)
        case .spotify:
            let script = """
            tell application "Spotify"
                try
                    return artwork url of current track
                on error
                    return ""
                end try
            end tell
            """
            guard let urlString = try? execute(script),
                  let url = URL(string: urlString),
                  url.scheme?.hasPrefix("http") == true,
                  let data = try? Data(contentsOf: url) else { return nil }
            return data
        case .none, .audioProcess:
            return nil
        }
    }

    func perform(_ control: MediaControl) throws {
        guard let source else { return }
        let app = source == .music ? "Music" : "Spotify"
        let command: String
        switch control {
        case .playPause: command = "playpause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        }
        _ = try execute("tell application \"\(app)\" to \(command)")
    }

    // MARK: - AppleScript 执行

    private func execute(_ source: String) throws -> String {
        let descriptor = try run(source)
        return descriptor.stringValue ?? ""
    }

    private func executeData(_ source: String) throws -> Data? {
        let descriptor = try run(source)
        guard descriptor.descriptorType == typeData else { return nil }
        return descriptor.data
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw MediaError.scriptCompileFailed
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { throw MediaError.notAuthorized }
            throw MediaError.scriptFailed(code: code)
        }
        return result
    }
}

enum MediaError: LocalizedError {
    case scriptCompileFailed
    case scriptFailed(code: Int)
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .scriptCompileFailed: return "AppleScript 编译失败"
        case .scriptFailed(let code): return "AppleScript 执行失败（\(code)）"
        case .notAuthorized: return "Automation 授权被拒绝（-1743）"
        }
    }
}

/// CoreAudio 监听的可观测状态，只给探针/自测断言用。
struct AudioMonitorStatus: Equatable {
    var isRunning = false
    /// 已挂上 `IsRunningOutput` 监听的音频进程对象数。
    var monitoredObjects = 0
    /// 系统当前音频进程对象总数。
    var audioProcesses = 0
}

/// 媒体服务：AppleScript 优先（有元数据），IOPM 兜底（任意播放器，只有状态）。
///
/// 刷新来源：
/// 1. 启动时各读一次；
/// 2. 播放器事件通知（Music / Spotify 的分布式通知），250ms 合并；
/// 3. 面板展开时一次 + 播放中每 5s 一次 AppleScript 校正；
/// 4. CoreAudio 音频进程监听（`AudioProcessMonitor`）——进程起停、输出开关变化时即时重读 IOPM；
/// 5. 只有「确实有 IOPM 断言」时，才挂一条 2s 的复核表。
///
/// 为什么还留一条表：暂停不会产生任何事件（IOPM 没有变更通知；CoreAudio 的
/// `IsRunningOutput` 在客户端自己暂停时实测仍为 1），只能靠复核发现断言被撤掉。
/// 这条表只在播放期间存在，暂停/退出/无播放时立即停掉 —— 空闲时定时器数为 0。
final class MediaService {
    /// 每个通道真实会向系统发起的权限请求。这里是「行为」的唯一声明处：
    /// 新增通道时 switch 穷尽会强制补分支，`--selftest` 再拿条目的声明逐条比对，
    /// 所以设置窗口里的权限说明不可能多于/少于代码实际行为。
    static func permissionsRequested(for channel: PlayerEntry.Channel) -> Set<PlayerEntry.Permission> {
        switch channel {
        case .automation:
            // AppleScript 会触发 Automation 授权。
            return [.automation]
        case .menuBar:
            // 只读 IOPM 整表，不针对单个 App，系统不弹任何授权。
            return []
        }
    }
    private let backend: MediaBackend
    private let presenceReader: () -> AudioPresence?
    private let monitor: AudioProcessMonitor
    private let queue = DispatchQueue(label: "notch.media.applescript", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: DispatchWorkItem?
    private var pollTimer: Timer?
    private var presenceVerifyTimer: Timer?
    private var isPanelOpen = false
    private var lastArtworkKey = ""

    private(set) var snapshot: MediaSnapshot = .none
    private(set) var permission: MediaPermission = .unknown
    /// CoreAudio 监听状态：展开态自测/探针用，证明事件源真的挂上了。
    private(set) var audioProcessMonitorStatus = AudioMonitorStatus()
    /// 「播放中复核表」实际触发次数，仅供 `--power-probe` 证明那条表真的在跑。
    private(set) var presenceVerifyFires = 0
    /// 拒绝授权后不再自动发 Apple Event，避免反复触发系统弹窗。
    private var autoRefreshSuspended = false
    /// AppleScript 通道的结果：有曲目时压过 IOPM。
    private var scripted: MediaSnapshot = .none
    /// IOPM 通道的结果：只有「谁在播」，没有曲目。
    private var presence: MediaSnapshot = .none

    /// 状态变化回调（主线程）。
    var onChange: ((MediaSnapshot, MediaPermission) -> Void)?

    init(
        backend: MediaBackend = AppleScriptBackend(),
        presence: @escaping () -> AudioPresence? = AudioPresenceReader.current,
        monitor: AudioProcessMonitor = AudioProcessMonitor()
    ) {
        self.backend = backend
        self.presenceReader = presence
        self.monitor = monitor
    }

    // MARK: - 生命周期

    func start() {
        registerPlayerObservers()
        monitor.onChange = { [weak self] in self?.refreshPresence() }
        monitor.start()
        refreshPresence()
        refresh()
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        monitor.stop()
        presenceVerifyTimer?.invalidate()
        presenceVerifyTimer = nil
        stopPolling()
    }

    /// 面板开合变化：展开时刷新一次并按需要开低频表，收起时停表。
    func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        if open {
            refresh()
            updatePolling()
        } else {
            stopPolling()
        }
    }

    /// 用户主动点「重试」：解除挂起并重新读一次（此时系统可能再次弹授权，是用户显式动作）。
    func retryAfterDenial() {
        autoRefreshSuspended = false
        refresh()
    }

    // MARK: - 事件

    private func registerPlayerObservers() {
        let names = ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"]
        for name in names {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            }
            observers.append(observer)
        }
    }

    /// 250ms 合并：连续切歌只会读一次。
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - IOPM 通道

    /// 只更新 IOPM 那一路；结果没变就不打扰界面。
    /// 事件源（CoreAudio 监听）与播放中复核表都从这里进来；`--power-probe` 用它做同进程 A/B。
    func refreshPresence() {
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.presenceReader()
            // 兼容开关的闸门：未开启的第三方播放器既不读也不显示。
            // IOPM 只能整表读（零权限、无 per-App 请求），所以这里拦在「是否采用这一条」上，
            // 保证未开启的播放器不会出现在界面上，也不会触发任何针对它的权限请求。
            let allowed = found.map { PlayerRegistry.allowsReading($0.bundleID) } ?? false
            let next = (allowed ? found : nil).map {
                MediaSnapshot.presence(
                    bundleID: $0.bundleID,
                    appName: $0.appName,
                    isMusicPlayer: MusicAppClassifier.isMusicPlayer(bundleID: $0.bundleID)
                )
            } ?? .none
            DispatchQueue.main.async {
                self.audioProcessMonitorStatus = AudioMonitorStatus(
                    isRunning: self.monitor.isRunning,
                    monitoredObjects: self.monitor.monitoredObjectCount,
                    audioProcesses: AudioProcessMonitor.processObjects().count
                )
                guard next != self.presence else {
                    self.updatePresenceVerification()
                    return
                }
                self.presence = next
                self.apply()
                self.updatePresenceVerification()
            }
        }
    }

    /// 复核表只在「有断言」期间存在：暂停/退出后断言消失，表随之停掉，
    /// 之后完全靠 CoreAudio 事件 + 启动读取把状态叫回来。
    private func updatePresenceVerification() {
        if presence.isPlaying, presenceVerifyTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.presenceVerifyFires += 1
                self.refreshPresence()
            }
            timer.tolerance = 0.5
            presenceVerifyTimer = timer
        } else if !presence.isPlaying {
            presenceVerifyTimer?.invalidate()
            presenceVerifyTimer = nil
        }
    }

    // MARK: - 读取

    func refresh() {
        guard !autoRefreshSuspended else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.backend.readSnapshot()
                var enriched = snapshot
                if snapshot.hasTrack {
                    if snapshot.trackKey != self.lastArtworkKey {
                        self.lastArtworkKey = snapshot.trackKey
                        enriched.artwork = try? self.backend.readArtwork()
                    } else {
                        enriched.artwork = self.scripted.artwork
                    }
                } else {
                    self.lastArtworkKey = ""
                }
                DispatchQueue.main.async {
                    self.permission = .granted
                    self.scripted = enriched
                    self.apply()
                    self.updatePolling()
                }
            } catch MediaError.notAuthorized {
                DispatchQueue.main.async {
                    self.permission = .denied
                    self.autoRefreshSuspended = true
                    self.scripted = .none
                    self.stopPolling()
                    self.apply()
                }
            } catch {
                DispatchQueue.main.async {
                    // 读失败不改授权状态：可能只是播放器刚好退出。
                    self.apply()
                }
            }
        }
    }

    /// 播放控制：只在已授权路径上执行，动作后立刻回读一次。
    func perform(_ control: MediaControl) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.backend.perform(control)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refresh() }
        }
    }

    // MARK: - 低频校正

    private func updatePolling() {
        let shouldPoll = isPanelOpen && snapshot.isPlaying
        if shouldPoll, pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            timer.tolerance = 2
            pollTimer = timer
        } else if !shouldPoll {
            stopPolling()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 合并

    /// 两条通道合流：有曲目用 AppleScript（带封面），没曲目但 IOPM 说在播就用状态快照。
    private func apply() {
        snapshot = scripted.hasTrack ? scripted : presence
        publish()
    }

    private func publish() {
        onChange?(snapshot, permission)
    }
}
