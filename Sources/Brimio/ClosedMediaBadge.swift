import SwiftUI

/// 闭合态右侧的媒体徽标：三种来源共用同一个 20×20 槽位。
///
/// 1. 有封面 → 封面缩略图；
/// 2. 有曲目没封面 → 三根跳动条（有曲名时才有资格“假装在动”）；
/// 3. 只有播放状态（IOPM 通道，没有曲目）→ 播放器的应用图标，取不到就退化成音符。
///
/// 闭合态**不放文字**：183pt 的形状正中就是摄像头模组的实体遮挡区。
struct ClosedMediaBadge: View {
    let media: MediaSnapshot

    var body: some View {
        Group {
            if media.isPresenceOnly {
                presenceIcon
            } else if let data = media.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: DesignSystem.Size.closedBadge, height: DesignSystem.Size.closedBadge)
                    .clipShape(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    )
            } else {
                EqualizerBars(isPlaying: media.isPlaying)
                    .frame(width: DesignSystem.Size.closedBadge, height: DesignSystem.Size.closedBadge)
            }
        }
        .accessibilityLabel(media.isPresenceOnly ? media.appName : media.title)
    }

    /// 播放器图标。取不到 App 图标时用音符占位，但仍然只占这一个槽位。
    private var presenceIcon: some View {
        Group {
            if let icon = AppIconCache.icon(forBundleID: media.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(DesignSystem.Spacing.xs)
            }
        }
        .frame(width: DesignSystem.Size.closedBadge, height: DesignSystem.Size.closedBadge)
        .clipShape(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
        )
    }
}

/// bundle id → 应用图标。图标在 App 生命周期内不变，查一次就缓存；
/// 找不到也缓存下来，避免每帧重复扫进程/磁盘。
@MainActor
enum AppIconCache {
    private enum Entry {
        case icon(NSImage)
        case missing
    }

    private static var cache: [String: Entry] = [:]

    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] {
            switch cached {
            case .icon(let image): return image
            case .missing: return nil
            }
        }
        let image = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image.map { Entry.icon($0) } ?? .missing
        return image
    }
}

/// 三根跳动条：仅在「有曲目但没有封面」时出现。
///
/// 用 `TimelineView(.periodic(by: 1/15))` 而不是 `repeatForever` 动画：
/// 15fps 足够让 20pt 见方的小块看起来是「在跳」而不是幻灯片（之前 2Hz / 0.45s
/// 一帧，人眼能数出台阶），同时每帧只重绘三根 Capsule，开销可以忽略。
/// 暂停时定在静态高度，完全不重绘。
private struct EqualizerBars: View {
    let isPlaying: Bool

    private static let heights: [CGFloat] = [0.45, 1.0, 0.65]
    private static let frameInterval = 1.0 / 15.0

    var body: some View {
        if isPlaying {
            TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                bars(phase: context.date.timeIntervalSince1970)
            }
        } else {
            bars(phase: 0)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Size.eqBarGap) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { index, base in
                // 3.2 rad/s 配上 abs(sin) 大约每秒一个起伏，接近真实电平表的节奏。
                let wobble = 0.75 + 0.25 * abs(sin(phase * 3.2 + Double(index) * 1.7))
                Capsule()
                    .fill(DesignSystem.Colors.textSecondary)
                    .frame(
                        width: DesignSystem.Size.eqBarWidth,
                        height: DesignSystem.Size.eqBarHeight * base * wobble
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
