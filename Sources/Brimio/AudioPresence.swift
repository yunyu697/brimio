import AppKit
import CoreAudio
import Foundation

/// 「某个 App 正在输出音频」的零权限信号。
///
/// 来源：`IOPMCopyAssertionsByProcess()`。coreaudiod 会为正在播声的进程建一条
/// `PreventUserIdleSystemSleep` 断言，`AssertName` 形如 `NetEase CloudMusic is playing music`，
/// 字典的键就是播放器的 pid。读它不需要任何 TCC 授权、不需要 entitlement。
struct AudioPresence: Equatable {
    var pid: pid_t
    var bundleID: String
    var appName: String
    /// 断言存在即代表正在输出音频；暂停时 coreaudiod 会撤掉这条断言。
    var isPlaying: Bool
    /// 断言的创建序号，用来在多路同时播放时挑最后开始的那一路。
    var assertionID: Int
}

/// IOPM 断言读取与解析。解析拆成纯函数，方便自测喂合成字典。
enum AudioPresenceReader {
    /// 断言名后缀。coreaudiod 用「<进程名> is playing music」命名，媒体播放在这里可被识别。
    private static let playingSuffix = "is playing music"

    private typealias CopyAssertionsFn = @convention(c) (UnsafeMutablePointer<CFDictionary?>?) -> IOReturn

    /// `IOPMCopyAssertionsByProcess` 不在 Swift 的 IOKit 模块里，按需 dlsym 一次。
    private static let copyAssertions: CopyAssertionsFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, "IOPMCopyAssertionsByProcess") else { return nil }
        return unsafeBitCast(symbol, to: CopyAssertionsFn.self)
    }()

    /// 当前正在播声的 App；多路同时播放时取最后创建的那条断言。
    static func current() -> AudioPresence? {
        guard let copyAssertions else { return nil }
        var dictionary: CFDictionary?
        // kIOReturnSuccess == 0
        guard copyAssertions(&dictionary) == 0,
              let raw = dictionary as? [NSNumber: [[String: Any]]] else { return nil }
        return presences(from: raw)
            .filter(\.isPlaying)
            .max { $0.assertionID < $1.assertionID }
    }

    /// 从原始断言字典解析出播放者。`resolve` 用来把 pid 换成 bundle id / 名称，
    /// 默认查 NSRunningApplication；自测可以注入固定映射。
    static func presences(
        from raw: [NSNumber: [[String: Any]]],
        resolve: (pid_t) -> (bundleID: String, appName: String)? = lookup
    ) -> [AudioPresence] {
        var result: [AudioPresence] = []
        for (pidKey, assertions) in raw {
            for assertion in assertions {
                guard let name = assertion["AssertName"] as? String,
                      name.hasSuffix(playingSuffix),
                      (assertion["AssertType"] as? String) == "PreventUserIdleSystemSleep"
                else { continue }
                let rawPID = (assertion["AssertPID"] as? NSNumber)?.int32Value ?? pidKey.int32Value
                let pid = pid_t(rawPID)
                guard let resolved = resolve(pid) else { continue }
                result.append(
                    AudioPresence(
                        pid: pid,
                        bundleID: resolved.bundleID,
                        appName: resolved.appName,
                        isPlaying: true,
                        assertionID: (assertion["AssertionId"] as? NSNumber)?.intValue ?? 0
                    )
                )
            }
        }
        return result
    }

    /// pid → 正在运行的 App。读不到（进程已退出）就当作没有信号。
    static func lookup(_ pid: pid_t) -> (bundleID: String, appName: String)? {
        guard let application = NSRunningApplication(processIdentifier: pid),
              let bundleID = application.bundleIdentifier else { return nil }
        return (bundleID, application.localizedName ?? bundleID)
    }
}

/// 一个 App 的类别实测结果，供 `--presence-probe` 打印真实数据。
struct MusicCategoryReport {
    var bundleID: String
    /// 实际读到 Info.plist 的那个 bundle；没运行也没装则为 nil。
    var appPath: String?
    /// `LSApplicationCategoryType` 原样值；没写这一项时也是 nil。
    var declaredCategory: String?
    var whitelisted: Bool
    /// 最终是否被当作音乐类播放器。
    var accepted: Bool
}

/// 判断一个进程是不是「音乐类播放器」。
///
/// IOPM 只知道「有进程在出声」：网页视频（Chrome/Safari）、微信语音、游戏都会命中；
/// 同类产品靠 Now Playing 会话天然只登记媒体 App，换成 IOPM 后丢了这层过滤。
/// 所以闭合态徽标只给音乐类 App，其余留在展开态由用户自己判断。
///
/// 判定顺序：**白名单优先，类别兜底**。
/// 反过来（类别优先、白名单只在类别缺失时生效）会误伤国内播放器：QQ 音乐、酷狗的
/// `LSApplicationCategoryType` 常自报 entertainment / utilities，不是 data bug，
/// 是厂商没按音乐类别填，按类别硬筛会把已经核过的白名单 App 挡掉。
enum MusicAppClassifier {
    static let musicCategory = "public.app-category.music"

    /// 核过的音乐类 App：命中即放行，不再看它自报的类别。
    static let whitelist: [String] = [
        "com.apple.Music",
        "com.spotify.client",
        "com.netease.163music",
        "com.tencent.QQMusic",
        "com.kugou.mac",
        "com.kuwo.KuwoMusic",
        "com.google.YouTubeMusic"
    ]

    private static let whitelistSet = Set(whitelist)
    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]
    private static let scanLock = NSLock()
    private static var installedURLs: [URL]?

    /// 判定规则本身拆成纯函数，自测可以直接喂类别，不用装 App。
    static func accepts(bundleID: String, category: String?) -> Bool {
        whitelistSet.contains(bundleID) || category == musicCategory
    }

    static func isMusicPlayer(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let report = categoryReport(bundleID: bundleID)

        lock.lock()
        cache[bundleID] = report.accepted
        lock.unlock()
        return report.accepted
    }

    /// 读 App 自报的类别：先看正在运行的实例，没运行就去常见 Applications 目录里按 bundle id 找。
    /// 国内不少播放器这一项写的是 entertainment / utilities，所以它只能当兜底，不能当主判据。
    static func declaredCategory(bundleID: String) -> String? {
        bundleURL(bundleID: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
    }

    static func categoryReport(bundleID: String) -> MusicCategoryReport {
        let url = bundleURL(bundleID: bundleID)
        let category = url.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        }
        return MusicCategoryReport(
            bundleID: bundleID,
            appPath: url?.path,
            declaredCategory: category,
            whitelisted: whitelistSet.contains(bundleID),
            accepted: accepts(bundleID: bundleID, category: category)
        )
    }

    static func bundleURL(bundleID: String) -> URL? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL {
            return running
        }
        return installedAppURLs().first { Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    /// 常见安装目录里的 .app（含 Setapp 这类容器目录下的一层），只扫一次。
    private static func installedAppURLs() -> [URL] {
        scanLock.lock()
        if let installedURLs {
            scanLock.unlock()
            return installedURLs
        }
        scanLock.unlock()

        let roots = [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        let fm = FileManager.default
        var result: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                result.append(url)
                if let children = try? fm.contentsOfDirectory(atPath: url.path) {
                    for child in children where child.hasSuffix(".app") {
                        result.append(url.appendingPathComponent(child))
                    }
                }
            }
        }

        scanLock.lock()
        installedURLs = result
        scanLock.unlock()
        return result
    }
}

/// CoreAudio 音频进程事件源：进程出现/消失、输出状态变化时回调。
///
/// 为什么需要它：IOPM 断言没有变更通知（实测给 `IOPMrootDomain` 挂 general-interest
/// 通知，音频客户端起停时一次都不触发），只能轮询。CoreAudio 的
/// `kAudioHardwarePropertyProcessObjectList` 与 `kAudioProcessPropertyIsRunningOutput`
/// 都支持属性监听，用它们把「开始/停止输出、App 启动/退出」变成回调，
/// 于是轮询只在「确实在播」时保留（见 `MediaService` 的 2s 复核）。
///
/// 边界：`IsRunningOutput` 的含义是「这个客户端挂着 IO proc」，不等于「有声音」。
/// 实测对一个自己 `AudioQueuePause` 的客户端，该属性全程为 1、回调 0 次；
/// 所以「是否在播」的语义判定仍以 IOPM 断言为准，这里只当触发器。
final class AudioProcessMonitor {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(label: "notch.audio.process-monitor", qos: .utility)
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var objectBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pendingPublish: DispatchWorkItem?
    private(set) var isRunning = false
    /// 当前挂着监听的音频进程对象数，供探针证明监听确实挂上了。
    private(set) var monitoredObjectCount = 0

    /// 有变化时回调，主线程。
    var onChange: (() -> Void)?

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 系统下所有音频进程对象。API 不可用时返回空数组。
    static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncObjects()
            self?.schedulePublish()
        }
        listBlock = block
        AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, block)
        syncObjects()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingPublish?.cancel()
        pendingPublish = nil
        if let listBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, queue, listBlock)
        }
        listBlock = nil
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for (object, block) in objectBlocks {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        objectBlocks.removeAll()
        monitoredObjectCount = 0
    }

    /// 让监听集合跟当前进程对象列表对齐：新增的挂上，消失的摘掉。
    private func syncObjects() {
        let current = Set(Self.processObjects())
        for object in objectBlocks.keys where !current.contains(object) {
            detach(object)
        }
        for object in current where objectBlocks[object] == nil {
            attach(object)
        }
        monitoredObjectCount = objectBlocks.count
    }

    private func attach(_ object: AudioObjectID) {
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.schedulePublish()
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        objectBlocks[object] = block
    }

    private func detach(_ object: AudioObjectID) {
        guard let block = objectBlocks.removeValue(forKey: object) else { return }
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    /// 一次变化常常连发两条回调（起/停各两次），120ms 内合并成一次重读。
    private func schedulePublish() {
        pendingPublish?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            DispatchQueue.main.async { self.onChange?() }
        }
        pendingPublish = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
