import SwiftUI
import AppKit

/// 右クリックメニュー。Windows 11 の簡略版メニューと同じ並びにする
@MainActor
enum ContextMenu {
    /// 項目を右クリックしたとき
    static func forItems(model: WindowModel, items: [FileItem]) -> NSMenu {
        let menu = NSMenu.make()
        let urls = items.map(\.url)
        let single = items.count == 1 ? items[0] : nil

        addIconRow(to: menu, [
            IconAction(symbol: "scissors", help: L("切り取り")) { model.cutSelection() },
            IconAction(symbol: "doc.on.doc", help: L("コピー")) { model.copySelection() },
            IconAction(symbol: "character.cursor.ibeam", help: L("名前の変更"), enabled: single != nil) { model.renameSelection() },
            IconAction(symbol: "square.and.arrow.up", help: L("共有")) { model.fileList?.shareSelection() },
            IconAction(symbol: "trash", help: L("削除")) { model.deleteSelection() },
        ])
        menu.addSeparator()

        menu.addAction(L("開く"), symbol: "arrow.up.forward.app") { model.open(items) }
        if let single, !single.isDirectory {
            menu.addSubmenu(L("プログラムから開く"), symbol: "square.grid.2x2") { sub in
                fillOpenWith(sub, model: model, url: single.url)
            }
        }
        if let single, single.isDirectory {
            menu.addAction(L("新しいタブで開く"), symbol: "plus.rectangle.on.rectangle") { model.newTab(url: single.url) }
            let pinned = QuickAccess.shared.isPinned(single.url)
            menu.addAction(pinned ? L("クイックアクセスからピン留めを外す") : L("クイックアクセスにピン留め"),
                           symbol: pinned ? "pin.slash" : "pin") {
                model.togglePin(single.url)
            }
        }
        menu.addSeparator()
        menu.addAction(L("ZIPに圧縮"), symbol: "doc.zipper") { model.compressSelection() }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "zip" }) {
            menu.addAction(L("ZIPを展開"), symbol: "archivebox") { model.extractSelection() }
        }
        menu.addAction(L("パスのコピー"), symbol: "link") { model.copyPath() }
        addExtras(to: menu, model: model, items: items)
        menu.addSeparator()
        menu.addAction(L("プロパティ"), symbol: "info.circle") { model.showProperties() }
        return menu
    }

    /// 空白部分を右クリックしたとき
    static func forBackground(model: WindowModel) -> NSMenu {
        let menu = NSMenu.make()
        menu.addSubmenu(L("表示"), symbol: "list.bullet") { Menus.fillView($0, model: model) }
        menu.addSubmenu(L("並べ替え"), symbol: "arrow.up.arrow.down") { Menus.fillSort($0, tab: model.tab) }
        menu.addAction(L("更新"), symbol: "arrow.clockwise") { model.tab.reload() }
        // 「最近使用した項目」はフォルダではないので、置く・作る・その場所で開く操作は出さない
        guard !model.tab.isRecents else { return menu }
        menu.addSeparator()
        menu.addAction(L("貼り付け"), symbol: "doc.on.clipboard", enabled: !Clipboard.shared.urls.isEmpty) { model.paste() }
        menu.addSubmenu(L("新規作成"), symbol: "plus.circle") { Menus.fillNew($0, model: model) }
        menu.addSeparator()
        menu.addAction(L("ターミナルで開く"), symbol: "terminal") { model.openTerminal() }
        addExtras(to: menu, model: model, items: [])
        menu.addSeparator()
        menu.addAction(L("プロパティ"), symbol: "info.circle") { model.showProperties() }
        return menu
    }

    /// タグと AI のサブメニュー
    private static func addExtras(to menu: NSMenu, model: WindowModel, items: [FileItem]) {
        if !items.isEmpty {
            menu.addSubmenu(L("タグ"), symbol: "tag") { fillTags($0, model: model, items: items) }
        }
        if SettingsStore.shared.aiEnabled {
            menu.addSubmenu(L("AI"), symbol: "sparkles") { model.fillAIMenu($0, items: items) }
        }
    }

    /// Finder と同じ並び（レッド、オレンジ、イエロー、グリーン、ブルー、パープル、グレイ）
    private static let tagOrder = [6, 7, 5, 2, 4, 3, 1]

    private static func fillTags(_ menu: NSMenu, model: WindowModel, items: [FileItem]) {
        for index in tagOrder where Tags.names.indices.contains(index) && Tags.colors.indices.contains(index) {
            let item = ActionItem(Tags.names[index], checked: items.allSatisfy { $0.tags.contains(index) }) {
                Tags.toggle(index, on: items.map(\.url))
                model.tab.reload()
            }
            item.image = dot(Tags.colors[index])
            menu.addItem(item)
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private static func fillOpenWith(_ menu: NSMenu, model: WindowModel, url: URL) {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)
        var apps = workspace.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        if apps.isEmpty {
            menu.addAction(L("開けるアプリケーションがありません"), enabled: false) {}
        }
        for (index, app) in apps.prefix(20).enumerated() {
            var title = FileManager.default.displayName(atPath: app.path)
            if title.hasSuffix(".app") { title.removeLast(4) }
            if app == defaultApp { title += L("（既定）") }
            let item = ActionItem(title) { model.open([url], with: app) }
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if index == 0, defaultApp != nil, apps.count > 1 {
                menu.addSeparator()
            }
        }
    }

    // MARK: 上部のアイコン行

    struct IconAction {
        let symbol: String
        let help: String
        var enabled = true
        let action: () -> Void
    }

    private static func addIconRow(to menu: NSMenu, _ actions: [IconAction]) {
        let item = NSMenuItem()
        let row = HStack(spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, entry in
                IconButton(symbol: entry.symbol, help: entry.help, enabled: entry.enabled, size: 15) {
                    menu.cancelTracking()
                    DispatchQueue.main.async { entry.action() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(minWidth: 220)
        let hosting = NSHostingView(rootView: row)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.autoresizingMask = [.width]
        item.view = hosting
        menu.addItem(item)
    }
}
