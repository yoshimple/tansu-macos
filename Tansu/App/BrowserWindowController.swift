import AppKit
import SwiftUI

/// ファイルマネージャーのウィンドウ1枚。メニューとキー操作を WindowModel に渡す
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: WindowModel

    init(state: WindowState?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        model = WindowModel(state: state)
        super.init(window: window)

        model.window = window
        window.contentView = NSHostingView(rootView: BrowserView(model: model))
        window.delegate = self
        if let frame = state?.frame {
            window.setFrame(NSRectFromString(frame), display: false)
        } else {
            window.center()
        }
        window.title = model.tab.title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        appDelegate?.windowWillClose(self)
    }

    func windowDidResize(_ notification: Notification) {
        appDelegate?.saveSession()
    }

    func windowDidMove(_ notification: Notification) {
        appDelegate?.saveSession()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        UndoCenter.shared.manager
    }

    // MARK: メニューからの操作

    @objc func newTab(_ sender: Any?) {
        model.newTab()
    }

    @objc func closeTab(_ sender: Any?) {
        model.closeTab(model.tab.id)
    }

    @objc func newFolder(_ sender: Any?) {
        model.newFolder()
    }

    @objc func copy(_ sender: Any?) {
        model.copySelection()
    }

    @objc func cut(_ sender: Any?) {
        model.cutSelection()
    }

    @objc func paste(_ sender: Any?) {
        model.paste()
    }

    override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    @objc func refresh(_ sender: Any?) {
        model.tab.reload()
    }

    @objc func focusAddress(_ sender: Any?) {
        model.addressEditing = true
    }

    @objc func focusSearch(_ sender: Any?) {
        model.searchFocusRequest += 1
    }

    @objc func changeViewMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(ViewMode.init(rawValue:)) else { return }
        model.tab.setViewMode(mode)
    }

    @objc func togglePreview(_ sender: Any?) {
        model.showPreview.toggle()
    }

    @objc func toggleNavigationPane(_ sender: Any?) {
        model.showSidebar.toggle()
    }

    @objc func toggleHidden(_ sender: Any?) {
        Prefs.shared.showHidden.toggle()
    }

    @objc func toggleExpandToOpenFolder(_ sender: Any?) {
        Prefs.shared.expandToOpenFolder.toggle()
    }

    @objc func showProperties(_ sender: Any?) {
        model.showProperties()
    }

    @objc func showShortcuts(_ sender: Any?) {
        model.showShortcuts()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(togglePreview(_:)):
            menuItem.state = model.showPreview ? .on : .off
        case #selector(toggleNavigationPane(_:)):
            menuItem.state = model.showSidebar ? .on : .off
        case #selector(changeViewMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == model.tab.viewMode.rawValue ? .on : .off
        case #selector(toggleHidden(_:)):
            menuItem.state = Prefs.shared.showHidden ? .on : .off
        case #selector(toggleExpandToOpenFolder(_:)):
            menuItem.state = Prefs.shared.expandToOpenFolder ? .on : .off
        case #selector(copy(_:)), #selector(cut(_:)):
            return !model.tab.selection.isEmpty
        case #selector(paste(_:)):
            return model.tab.directory != nil && !Clipboard.shared.urls.isEmpty
        case #selector(newFolder(_:)):
            return model.tab.directory != nil && !isEditingText
        case #selector(refresh(_:)), #selector(showProperties(_:)):
            // 文字入力中は、入力を優先する
            return !isEditingText
        default:
            break
        }
        return true
    }

    // MARK: キー操作

    /// 文字入力中かどうか（名前変更、アドレスバー、検索ボックス）
    private var isEditingText: Bool {
        window?.firstResponder is NSTextView
    }

    /// キー入力を処理したら true を返す。文字入力中は何もしない
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !isEditingText else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let tab = model.tab

        // Tab／F6 で、ナビゲーションウィンドウとファイル一覧の間でフォーカスを移す
        if (event.keyCode == 48 && flags.subtracting(.shift).isEmpty) || (event.keyCode == 97 && flags.isEmpty) {
            if sidebarActive {
                model.focusFileList()
            } else {
                model.focusSidebar()
            }
            return true
        }
        if sidebarActive, let handled = handleSidebarKey(event, flags: flags) {
            return handled
        }

        // 特殊キーはキーコードで判定する
        switch (event.keyCode, flags) {
        case (36, []), (76, []):            // Enter
            model.openSelection()
        case (36, .option), (76, .option):  // Option+Enter
            showProperties(nil)
        case (120, []):                     // F2
            model.renameSelection()
        case (96, []):                      // F5
            tab.reload()
        case (51, []):                      // ⌫
            tab.goUp()
        case (51, .command), (117, []):     // Cmd+⌫、前方削除
            model.deleteSelection()
        case (126, .option):                // Option+↑
            tab.goUp()
        case (123, .option):                // Option+←
            tab.goBack()
        case (124, .option):                // Option+→
            tab.goForward()
        case (49, []):                      // Space
            model.fileList?.toggleQuickLook()
        case (53, []):                      // Esc
            Clipboard.shared.clearCut()
            // 検索結果の表示中なら、検索だけを解除して元のフォルダの一覧に戻る
            guard tab.isSearching else { return false }
            tab.searchText = ""
        default:
            return handleCharacterKey(event, flags: flags)
        }
        return true
    }

    /// ナビゲーションウィンドウにフォーカスがあるか。ファイル一覧をクリックした直後は一覧を優先する
    private var sidebarActive: Bool {
        guard model.showSidebar, model.sidebar.hasFocus else { return false }
        let responder = window?.firstResponder
        return !(responder is NSTableView || responder is NSCollectionView)
    }

    /// ナビゲーションウィンドウでのキー操作。ほかの処理に任せるキーは nil を返す
    private func handleSidebarKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        let sidebar = model.sidebar
        switch (event.keyCode, flags) {
        case (126, []):                     // ↑
            model.showSidebarRow(sidebar.moveSelection(by: -1))
        case (125, []):                     // ↓
            model.showSidebarRow(sidebar.moveSelection(by: 1))
        case (124, []):                     // →
            model.showSidebarRow(sidebar.moveRight())
        case (123, []):                     // ←
            model.showSidebarRow(sidebar.moveLeft())
        case (36, []), (76, []), (53, []):  // Enter、Esc はファイル一覧へ戻る
            model.focusFileList()
        case (49, []), (120, []), (117, []), (51, .command):
            // Space、F2、削除は一覧で選んだ項目への操作なので、ここでは行わない
            break
        default:
            // 文字入力で一覧の項目へジャンプしないようにする
            guard flags.subtracting(.shift).isEmpty,
                  let scalar = event.characters?.unicodeScalars.first,
                  scalar.value > 0x20, scalar.value != 0x7F,
                  !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        }
        return true
    }

    /// 文字キーは、キーボード配列に左右されないよう文字で判定する
    private func handleCharacterKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else { return false }
        switch (characters, flags) {
        case ("[", .command):
            model.tab.goBack()
        case ("]", .command):
            model.tab.goForward()
        case ("d", .option):
            model.addressEditing = true
        case ("e", .command):
            model.searchFocusRequest += 1
        case ("p", .option):
            model.showPreview.toggle()
        default:
            // 修飾キーなしの文字入力は、その文字で始まる項目へジャンプする
            guard flags.subtracting(.shift).isEmpty,
                  let typed = event.characters,
                  let scalar = typed.unicodeScalars.first,
                  scalar.value > 0x20, scalar.value != 0x7F,
                  !(0xF700...0xF8FF).contains(scalar.value) else { return false }
            model.fileList?.typeSelect(typed)
        }
        return true
    }
}
