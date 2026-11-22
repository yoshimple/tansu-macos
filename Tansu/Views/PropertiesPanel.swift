import SwiftUI
import AppKit

/// プロパティのダイアログ。種類、場所、サイズ、作成日時、更新日時だけを表示する
@MainActor
enum PropertiesPanel {
    private static var panels: [NSPanel] = []

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let title = urls.count == 1
            ? L("%@のプロパティ", FileManager.default.displayName(atPath: urls[0].path))
            : L("%d個の項目のプロパティ", urls.count)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PropertiesView(urls: urls) { [weak panel] in panel?.close() })
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 380, height: 260))
        panel.center()
        // 閉じたパネルは次に開くときに手放す
        panels.removeAll { !$0.isVisible }
        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct PropertiesView: View {
    let urls: [URL]
    let close: () -> Void
    @State private var sizeText = L("計算中…")

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        let first = urls[0]
        let single = urls.count == 1
        let values = try? first.resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey])
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(single ? first.lastPathComponent : L("%d個の項目", urls.count))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                if single {
                    row(L("種類"), values?.localizedTypeDescription ?? "")
                }
                row(L("場所"), first.deletingLastPathComponent().path)
                row(L("サイズ"), sizeText)
                if single {
                    row(L("作成日時"), values?.creationDate.map(Self.dateFormatter.string(from:)) ?? "")
                    row(L("更新日時"), values?.contentModificationDate.map(Self.dateFormatter.string(from:)) ?? "")
                }
            }
            HStack {
                Spacer()
                Button(L("OK")) { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
        .task {
            let urls = urls
            let (bytes, count) = await Task.detached(priority: .utility) { Self.measure(urls) }.value
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let size = formatter.string(fromByteCount: bytes)
            let exact = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
            sizeText = L("%@（%@ バイト）", size, exact) + (count > 1 ? "\n" + L("%d個の項目", count) : "")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }

    /// 合計サイズと項目数（フォルダは中身を数える）
    nonisolated private static func measure(_ urls: [URL]) -> (Int64, Int) {
        var bytes: Int64 = 0
        var count = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { continue }
                for case let child as URL in enumerator {
                    if Task.isCancelled { return (bytes, count) }
                    let childValues = try? child.resourceValues(forKeys: keys)
                    if childValues?.isDirectory != true {
                        bytes += Int64(childValues?.fileSize ?? 0)
                    }
                    count += 1
                }
            } else {
                bytes += Int64(values?.fileSize ?? 0)
                count += 1
            }
        }
        return (bytes, count)
    }
}
