import AppKit

/// コマンドバーと右クリックメニューで共通に使うメニューの中身
@MainActor
enum Menus {
    static func fillSort(_ menu: NSMenu, tab: TabModel) {
        let keys: [(SortKey, String)] = [
            (.name, L("名前")), (.modified, L("更新日時")), (.kind, L("種類")), (.size, L("サイズ")),
        ]
        for (key, title) in keys {
            menu.addAction(title, checked: !tab.usesQueryOrder && tab.sortKey == key) { tab.setSort(key, ascending: tab.sortAscending) }
        }
        menu.addSeparator()
        menu.addAction(L("昇順"), checked: !tab.usesQueryOrder && tab.sortAscending) { tab.setSort(tab.sortKey, ascending: true) }
        menu.addAction(L("降順"), checked: !tab.usesQueryOrder && !tab.sortAscending) { tab.setSort(tab.sortKey, ascending: false) }
    }

    static func fillNew(_ menu: NSMenu, model: WindowModel) {
        menu.addAction(L("フォルダー"), symbol: "folder") { model.newFolder() }
        menu.addAction(L("テキスト ドキュメント"), symbol: "doc.text") { model.newTextFile() }
    }

    static func fillMore(_ menu: NSMenu, model: WindowModel) {
        menu.addAction(L("すべて選択"), symbol: "checklist") { model.selectAll() }
        menu.addAction(L("選択解除"), symbol: "xmark.square") { model.deselectAll() }
        menu.addSeparator()
        menu.addAction(L("パスのコピー"), symbol: "link") { model.copyPath() }
        menu.addAction(L("ターミナルで開く"), symbol: "terminal") { model.openTerminal() }
        menu.addSeparator()
        menu.addAction(L("プロパティ"), symbol: "info.circle") { model.showProperties() }
    }

    static func fillView(_ menu: NSMenu, model: WindowModel) {
        let tab = model.tab
        let modes: [(ViewMode, String, String)] = [
            (.details, L("詳細"), "list.bullet"),
            (.icons, L("大アイコン"), "square.grid.2x2"),
            (.list, L("一覧"), "list.bullet.indent"),
        ]
        for (mode, title, symbol) in modes {
            menu.addAction(title, symbol: symbol, checked: tab.viewMode == mode) { tab.setViewMode(mode) }
        }
        menu.addSeparator()
        menu.addAction(L("プレビューウィンドウ"), symbol: "sidebar.right", checked: model.showPreview) {
            model.showPreview.toggle()
        }
        menu.addAction(L("隠しファイル"), symbol: "eye", checked: Prefs.shared.showHidden) {
            Prefs.shared.showHidden.toggle()
        }
        menu.addAction(L("ファイル名拡張子"), symbol: "doc", checked: Prefs.shared.showExtensions) {
            Prefs.shared.showExtensions.toggle()
        }
        menu.addAction(L("開いているフォルダーまで展開"), symbol: "arrow.turn.down.right", checked: Prefs.shared.expandToOpenFolder) {
            Prefs.shared.expandToOpenFolder.toggle()
        }
    }
}
