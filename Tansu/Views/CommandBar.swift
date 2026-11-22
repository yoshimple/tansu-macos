import SwiftUI
import AppKit

/// 新規作成、ファイル操作、並べ替え、表示、その他のボタンが並ぶ行
struct CommandBar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    @State private var shareAnchor = AnchorBox()

    var body: some View {
        let hasSelection = !tab.selection.isEmpty
        HStack(spacing: 2) {
            MenuButton(help: L("新規作成"), menu: {
                let menu = NSMenu.make()
                Menus.fillNew(menu, model: model)
                return menu
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle").font(.system(size: 14))
                    Text(L("新規作成")).font(.system(size: 13))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .disabled(tab.directory == nil)
            separator
            IconButton(symbol: "scissors", help: L("切り取り"), enabled: hasSelection) { model.cutSelection() }
            IconButton(symbol: "doc.on.doc", help: L("コピー"), enabled: hasSelection) { model.copySelection() }
            IconButton(symbol: "doc.on.clipboard", help: L("貼り付け"), enabled: tab.directory != nil) { model.paste() }
            IconButton(symbol: "character.cursor.ibeam", help: L("名前の変更"), enabled: tab.selection.count == 1) {
                model.renameSelection()
            }
            IconButton(symbol: "square.and.arrow.up", help: L("共有"), enabled: hasSelection) {
                model.share(from: shareAnchor.view)
            }
            .background(AnchorView(box: shareAnchor))
            IconButton(symbol: "trash", help: L("削除"), enabled: hasSelection) { model.deleteSelection() }
            separator
            MenuButton(help: L("並べ替え"), menu: {
                let menu = NSMenu.make()
                Menus.fillSort(menu, tab: tab)
                return menu
            }) {
                dropdownLabel(symbol: "arrow.up.arrow.down", title: L("並べ替え"))
            }
            MenuButton(help: L("表示"), menu: {
                let menu = NSMenu.make()
                Menus.fillView(menu, model: model)
                return menu
            }) {
                dropdownLabel(symbol: "list.bullet", title: L("表示"))
            }
            separator
            MenuButton(help: L("その他"), menu: {
                let menu = NSMenu.make()
                Menus.fillMore(menu, model: model)
                return menu
            }) {
                Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 30)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Theme.toolbar)
    }

    private var separator: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 5)
    }

    private func dropdownLabel(symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(title).font(.system(size: 13))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}
