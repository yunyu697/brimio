import AppKit
import SwiftUI

/// 播放器兼容设置页（独立窗口）。
///
/// 不放进刘海面板：7 个播放器 × 3 行说明远超面板 190pt 的高度上限，
/// 而「每项必须写清权限 / 收益 / 不开的后果」不能压缩成一行。
struct PlayerSettingsView: View {
    @ObservedObject var vm: NotchViewModel
    let onTogglePlayer: (String, Bool) -> Void

    var body: some View {
        // 读版本号：开关变化后整页重算。
        let version = vm.playerSettingsVersion
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("系统播放器")
                .textLineBox(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("首次读取时由系统弹一次 Automation 授权，权限只针对该 App。")
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            ForEach(PlayerRegistry.entries.filter { !$0.isThirdParty }) { entry in
                row(entry, version: version)
            }

            Text("第三方播放器（默认关闭）")
                .textLineBox(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.top, DesignSystem.Spacing.sm)
            Text("未开启的播放器不读取、不显示；这一组不需要额外权限。")
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            ForEach(PlayerRegistry.entries.filter(\.isThirdParty)) { entry in
                row(entry, version: version)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: DesignSystem.Size.settingsWidth, alignment: .leading)
        .background(DesignSystem.Colors.surface)
    }

    private func row(_ entry: PlayerEntry, version: Int) -> some View {
        let enabled = PlayerRegistry.isEnabled(entry.bundleID)
        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.none) {
                Text(entry.name)
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                detail("需要：\(entry.permission)")
                detail("开启后：\(entry.benefit)")
                detail("不开：\(entry.disabledEffect)")
            }
            Spacer(minLength: DesignSystem.Spacing.none)
            if entry.isThirdParty {
                PlayerToggle(isOn: enabled) { onTogglePlayer(entry.bundleID, $0) }
            } else {
                Text("默认开")
                    .textLineBox(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .textLineBox(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
    }
}

/// 自绘开关。
///
/// `Toggle` 是 AppKit 控件，`ImageRenderer` 离屏渲染画不出它（会变成占位符），
/// 那样渲染图和真窗口就是两回事。这里用 SwiftUI 图形画，两边一致。
private struct PlayerToggle: View {
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Capsule()
            .fill(isOn ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.badgeFill)
            .frame(width: DesignSystem.Size.switchWidth, height: DesignSystem.Size.switchHeight)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? DesignSystem.Colors.surface : DesignSystem.Colors.textSecondary)
                    .frame(width: DesignSystem.Size.switchKnob, height: DesignSystem.Size.switchKnob)
                    .padding(DesignSystem.Size.switchInset)
            }
            .contentShape(Capsule())
            .onTapGesture { onChange(!isOn) }
            .accessibilityElement()
            .accessibilityLabel(isOn ? "已开启" : "已关闭")
            .accessibilityAddTraits(.isButton)
    }
}

/// 设置窗口的唯一入口：同一时刻只留一个窗口，重复点击只前置。
@MainActor
final class PlayerSettingsWindowController {
    private var window: NSWindow?

    func show(vm: NotchViewModel, onTogglePlayer: @escaping (String, Bool) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(
            rootView: PlayerSettingsView(vm: vm, onTogglePlayer: onTogglePlayer)
        )
        let fallback = NSSize(
            width: DesignSystem.Size.settingsWidth,
            height: DesignSystem.Size.settingsFallbackHeight
        )
        let sized = hosting.fittingSize
        let size = (sized.width > 0 && sized.height > 0) ? sized : fallback
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Naming.settingsWindowTitle
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
