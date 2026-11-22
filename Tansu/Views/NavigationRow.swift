import SwiftUI

/// 戻る・進む・上へ・更新、アドレスバー、検索ボックスの行
struct NavigationRow: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow.left", help: L("戻る"), enabled: tab.canGoBack) { tab.goBack() }
            IconButton(symbol: "arrow.right", help: L("進む"), enabled: tab.canGoForward) { tab.goForward() }
            IconButton(symbol: "arrow.up", help: L("上へ"), enabled: tab.canGoUp) { tab.goUp() }
            IconButton(symbol: "arrow.clockwise", help: L("更新")) { tab.reload() }
            AddressBar(model: model, tab: tab)
                .padding(.leading, 4)
            SearchField(model: model, tab: tab)
                .frame(width: 230)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Theme.toolbar)
    }
}

struct SearchField: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(L("%@の検索", tab.folderName), text: $tab.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { model.focusFileList() }
                .onExitCommand {
                    tab.searchText = ""
                    model.focusFileList()
                }
            if !tab.searchText.isEmpty {
                Button {
                    tab.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.content))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
    }
}
