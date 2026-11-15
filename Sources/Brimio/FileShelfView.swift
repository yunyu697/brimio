import AppKit
import SwiftUI

/// 文件架条目：只保存 URL 引用与只读元数据，不拷贝文件、不解析内容。
struct ShelfItem: Identifiable, Equatable {
    let url: URL
    let fileSize: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// 40pt 槽位能放下的最宽形态（不超过 6 个字符）。
    var formattedSize: String { ShelfItem.format(fileSize) }

    /// 定长格式化，不用 `ByteCountFormatter`：后者跟随语言环境，
    /// 同一个文件在不同语言下宽度不同，会把右侧槽位撑开或截断。
    static func format(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        guard bytes >= 1024 else { return "\(bytes) B" }
        var value = Double(bytes) / 1024
        var unit = 1
        // 999.5 就进到下一档：保证「数字 + 空格 + 单位」不超过 6 个字符。
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return value < 10
            ? String(format: "%.1f %@", value, units[unit])
            : String(format: "%.0f %@", value, units[unit])
    }
}

/// 文件架的数据规则：置顶、去重、移除、清理失效引用。
///
/// 全部是纯函数（`inout [ShelfItem]`），方便在 `--selftest` 里直接断言，
/// 不需要起窗口，也不需要定时器。
enum FileShelfStore {
    /// 只读元数据：是否存在、是否普通文件、大小。不读内容、不生成缩略图。
    /// 用 `FileManager` 而不是 `URL.resourceValues`：后者对刚被移走的路径
    /// 偶尔仍返回缓存中的 `isRegularFile`，会把死链判成活链。
    static func makeItem(for url: URL) -> ShelfItem? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return ShelfItem(url: url, fileSize: size)
    }

    /// 新条目插到顶部；同路径重复拖入只提到顶部、不新增。返回真正新增的条数。
    @discardableResult
    static func add(_ urls: [URL], to items: inout [ShelfItem]) -> Int {
        var added = 0
        for url in urls.reversed() {
            let normalized = url.standardizedFileURL
            if let index = items.firstIndex(where: { $0.url.path == normalized.path }) {
                let existing = items.remove(at: index)
                items.insert(existing, at: 0)
                continue
            }
            guard let item = makeItem(for: normalized) else { continue }
            items.insert(item, at: 0)
            added += 1
        }
        return added
    }

    static func remove(url: URL, from items: inout [ShelfItem]) {
        items.removeAll { $0.url.path == url.standardizedFileURL.path }
    }

    /// 只在用户动作时调用（展开、拖入、点击），不挂定时器。
    /// 路径不存在或不再是普通文件 → 移除，返回被移除的文件名。
    @discardableResult
    static func pruneMissing(_ items: inout [ShelfItem]) -> [String] {
        var removed: [String] = []
        items.removeAll { item in
            let alive = makeItem(for: item.url) != nil
            if !alive { removed.append(item.name) }
            return !alive
        }
        return removed
    }

    /// 拖出完成时的规则：move 已经改变原路径 → 立即移除；copy 原文件还在 → 保留。
    @discardableResult
    static func applyDragOut(
        url: URL,
        operation: NSDragOperation,
        items: inout [ShelfItem]
    ) -> Bool {
        guard operation == .move else { return false }
        let before = items.count
        remove(url: url, from: &items)
        return items.count != before
    }
}

/// 文件架的几何：全部由 `DesignSystem` 档位推出，视图里不写裸值。
///
/// 视口 = 3 整行 + 3 个行间距 + 第 4 行露出的 20pt = 140pt。
/// 不靠滚动条提示溢出（macOS 默认「滚动时显示」，静止时看不见），
/// 露出的那 20pt 就是唯一的溢出线索：只露 8pt 时看到的是图标顶部一条白杠，
/// 读起来像脏点；20pt 能看到图标主体与文件名上半行，才读得出「下面还有一条」。
enum FileShelfLayout {
    static let rowHeight = DesignSystem.Control.lg
    static let rowGap = DesignSystem.Spacing.sm
    /// 大小槽位固定宽度：最宽形态「999 KB」约 36pt，留 4pt 余量。
    static let sizeSlotWidth: CGFloat = 40
    static let visibleRows = 3
    /// 第 4 行露出的高度：20pt（控件阶梯 xs 档）。
    static let peekHeight = DesignSystem.Control.xs
    static let viewportHeight = rowHeight * CGFloat(visibleRows)
        + rowGap * CGFloat(visibleRows)
        + peekHeight

    static func contentHeight(count: Int) -> CGFloat {
        switch count {
        case 0, 1: return rowHeight
        case 2: return rowHeight * 2 + rowGap
        case 3: return rowHeight * 3 + rowGap * 2
        default: return viewportHeight
        }
    }
}

/// 离屏渲染开关（只在 `--render` 里置位）。
///
/// `ImageRenderer` 不支持 `ScrollView`，会把内容画成占位块；
/// 渲染时改用同尺寸的裁剪容器，裁出来的可见区域与运行时滚动视口一致，
/// 因此「第 4 行露出 20pt」在图上仍然成立。运行时不走这条分支。
enum FileShelfRendering {
    @MainActor static var isOffscreen = false
}

/// hover 状态放在引用类型里：`@State` 依赖 SwiftUI 宏，本仓库的 SwiftPM
/// 工具链插件在这台机器上不可用，用 `ObservableObject` 保持同样的语义。
@MainActor
final class ShelfHoverState: ObservableObject {
    @Published var id: String?
}

/// 文件架正文：空态虚线框，或有文件时的一屏三行（第 4 行起滚动）。
struct FileShelfView: View {
    let items: [ShelfItem]
    let onRemove: (ShelfItem) -> Void

    @StateObject private var hover = ShelfHoverState()

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else if FileShelfRendering.isOffscreen {
                // 离屏：同尺寸裁剪，等价于滚动视口的可见区域。
                rows
                    .frame(height: FileShelfLayout.contentHeight(count: items.count), alignment: .top)
                    .clipped()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    rows
                }
            }
        }
        .frame(height: FileShelfLayout.contentHeight(count: items.count), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text("暂无文件，拖入后在这里显示。")
            .textLineBox(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: FileShelfLayout.rowHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .strokeBorder(
                        DesignSystem.Colors.divider,
                        style: StrokeStyle(
                            lineWidth: DesignSystem.Size.hairline,
                            dash: [DesignSystem.Spacing.xs, DesignSystem.Spacing.xs]
                        )
                    )
            )
    }

    private var rows: some View {
        VStack(spacing: FileShelfLayout.rowGap) {
            ForEach(items) { item in
                row(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: ShelfItem) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: DesignSystem.Size.fileIcon, height: DesignSystem.Size.fileIcon)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .textLineBox(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing(item)
        }
        .frame(height: FileShelfLayout.rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hover.id = item.id
            } else if hover.id == item.id {
                hover.id = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(item.formattedSize)")
    }

    /// 右侧槽位固定 40pt：hover 时用 × 替换大小，宽度不变，不产生回流。
    @ViewBuilder
    private func trailing(_ item: ShelfItem) -> some View {
        if hover.id == item.id {
            Button {
                onRemove(item)
            } label: {
                Image(systemName: "xmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: DesignSystem.Size.icon, height: DesignSystem.Size.icon)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: DesignSystem.Control.sm, height: DesignSystem.Control.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: FileShelfLayout.sizeSlotWidth)
            .accessibilityLabel("从文件架移除 \(item.name)")
        } else {
            Text(item.formattedSize)
                .lineLimit(1)
                .textLineBox(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: FileShelfLayout.sizeSlotWidth, alignment: .trailing)
        }
    }
}

/// 接收 Finder 拖来的文件：只取 `fileURL`，不读内容。
///
/// 多个文件先收齐再一次性加入，避免逐条插入让顺序反转。
struct FileDropDelegate: DropDelegate {
    let onFiles: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                if let url = object {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { onFiles(urls) }
        return true
    }
}
