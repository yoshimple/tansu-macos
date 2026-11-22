import SwiftUI

/// 最下部の行。項目数と選択状態、右端に表示形式の切り替え
struct StatusBar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    @State private var tokens: Int?

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 14) {
            Text(L("%d個の項目", tab.items.count))
            if !tab.selection.isEmpty {
                Text(selectionText)
            }
            if let tokens, tokens > 0 {
                Text(L("約%@トークン", AIExport.formatTokens(tokens)))
                    .toolTip(L("選択中のファイルをAIに渡したときの推定トークン数"))
            }
            Spacer(minLength: 0)
            if let branch = tab.git?.branch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
            modeButton(.details, symbol: "list.bullet", help: L("詳細"))
            modeButton(.icons, symbol: "square.grid.2x2", help: L("大アイコン"))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.toolbar)
        .task(id: tab.selection) {
            await updateTokens()
        }
    }

    /// 選択中のファイルの推定トークン数を、少し待ってから数える
    private func updateTokens() async {
        tokens = nil
        guard SettingsStore.shared.aiEnabled else { return }
        let files = tab.selectedItems.filter { !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let count = await Task.detached(priority: .utility) { AIExport.estimateTokens(of: files) }.value
        if !Task.isCancelled {
            tokens = count
        }
    }

    private var selectionText: String {
        let selected = tab.selectedItems
        let files = selected.filter { !$0.isDirectory }
        var text = L("%d個の項目を選択", selected.count)
        if !files.isEmpty, files.count == selected.count {
            text += "  " + Self.sizeFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size })
        }
        return text
    }

    private func modeButton(_ mode: ViewMode, symbol: String, help: String) -> some View {
        Button {
            tab.setViewMode(mode)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(tab.viewMode == mode ? Theme.selected : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .toolTip(help)
    }
}
