import AppKit

/// メニューバー。項目は最低限にして、主な操作はウィンドウ内のコマンドバーに置く
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = addMenu("Tansu", to: main)
        appMenu.addItem(withTitle: L("Tansuについて"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("設定…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Tansuを隠す"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, L("ほかを隠す"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        appMenu.addItem(withTitle: L("すべてを表示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Tansuを終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = addMenu(L("ファイル"), to: main)
        file.addItem(withTitle: L("新しいウィンドウ"), action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L("新しいタブ"), action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        item(file, L("新しいフォルダー"), #selector(BrowserWindowController.newFolder(_:)), "n", [.command, .shift])
        file.addItem(.separator())
        file.addItem(withTitle: L("タブを閉じる"), action: #selector(AppDelegate.closeTab(_:)), keyEquivalent: "w")

        let edit = addMenu(L("編集"), to: main)
        edit.addItem(withTitle: L("元に戻す"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("切り取り"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("コピー"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("貼り付け"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("すべて選択"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        let view = addMenu(L("表示"), to: main)
        view.addItem(withTitle: L("更新"), action: #selector(BrowserWindowController.refresh(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: L("アドレスバーへ移動"), action: #selector(BrowserWindowController.focusAddress(_:)), keyEquivalent: "l")
        view.addItem(withTitle: L("検索"), action: #selector(BrowserWindowController.focusSearch(_:)), keyEquivalent: "f")
        view.addItem(.separator())
        for (mode, title) in [(ViewMode.details, L("詳細")), (.icons, L("大アイコン")), (.list, L("一覧"))] {
            let item = view.addItem(withTitle: title, action: #selector(BrowserWindowController.changeViewMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
        }
        view.addItem(.separator())
        item(view, L("ナビゲーションウィンドウ"), #selector(BrowserWindowController.toggleNavigationPane(_:)), "s", [.command, .option])
        view.addItem(withTitle: L("プレビューウィンドウ"), action: #selector(BrowserWindowController.togglePreview(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("隠しファイル"), action: #selector(BrowserWindowController.toggleHidden(_:)), keyEquivalent: "")
        view.addItem(withTitle: L("開いているフォルダーまで展開"), action: #selector(BrowserWindowController.toggleExpandToOpenFolder(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: L("プロパティ"), action: #selector(BrowserWindowController.showProperties(_:)), keyEquivalent: "i")

        let window = addMenu(L("ウィンドウ"), to: main)
        window.addItem(withTitle: L("しまう"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("拡大／縮小"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = addMenu(L("ヘルプ"), to: main)
        help.addItem(withTitle: L("キー操作の一覧"), action: #selector(BrowserWindowController.showShortcuts(_:)), keyEquivalent: "")
        NSApp.helpMenu = help

        return main
    }

    private static func addMenu(_ title: String, to main: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
    }
}
