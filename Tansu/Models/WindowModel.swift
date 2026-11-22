import AppKit

/// ウィンドウ1つ分の状態（タブ、プレビューの表示）と、画面から呼ばれる操作
@MainActor
final class WindowModel: ObservableObject {
    @Published private(set) var tabs: [TabModel] {
        didSet { (NSApp.delegate as? AppDelegate)?.saveSession() }
    }
    @Published private(set) var selectedTabID: UUID {
        didSet { (NSApp.delegate as? AppDelegate)?.saveSession() }
    }
    @Published var showPreview: Bool {
        didSet { (NSApp.delegate as? AppDelegate)?.saveSession() }
    }
    @Published var showSidebar: Bool {
        didSet {
            if !showSidebar, sidebar.hasFocus { focusFileList() }
            (NSApp.delegate as? AppDelegate)?.saveSession()
        }
    }
    /// アドレスバーがテキスト入力中か
    @Published var addressEditing = false
    /// 値が変わると検索ボックスにフォーカスを移す
    @Published var searchFocusRequest = 0
    /// 画面下に短時間出す通知
    @Published var toast: String?

    weak var window: NSWindow?
    weak var fileList: FileListViewController?
    let sidebar = SidebarModel()
    private var toastWork: DispatchWorkItem?

    init(state: WindowState?) {
        let recents = TabModel.recentsURL
        let urls = state?.tabs.map { $0 == recents.absoluteString ? recents : URL(fileURLWithPath: $0) } ?? []
        let models = (urls.isEmpty ? [recents] : urls).map { TabModel(url: $0) }
        tabs = models
        let index = min(max(state?.selected ?? 0, 0), models.count - 1)
        selectedTabID = models[index].id
        showPreview = state?.showPreview ?? false
        showSidebar = state?.showSidebar ?? true
    }

    var tab: TabModel {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    var state: WindowState {
        WindowState(
            frame: window.map { NSStringFromRect($0.frame) },
            tabs: tabs.map { $0.isRecents ? TabModel.recentsURL.absoluteString : $0.url.path },
            selected: tabs.firstIndex { $0.id == selectedTabID } ?? 0,
            showPreview: showPreview,
            showSidebar: showSidebar)
    }

    // MARK: タブ

    func newTab(url: URL? = nil) {
        let model = TabModel(url: url ?? TabModel.recentsURL)
        tabs.append(model)
        selectedTabID = model.id
    }

    func selectTab(_ id: UUID) {
        guard selectedTabID != id else { return }
        addressEditing = false
        selectedTabID = id
    }

    /// タブを閉じる。最後の1つならウィンドウごと閉じる
    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else {
            window?.performClose(nil)
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// 項目の親フォルダを開き、その項目を選択する。他のアプリからの表示要求で使う。
    /// すでにそのフォルダを開いているタブがあれば、そのタブを使う
    func reveal(_ urls: [URL]) {
        var order: [URL] = []
        var groups: [URL: Set<URL>] = [:]
        for url in urls.map(\.normalizedFile) {
            // 「/」のように親がない場所は、その場所自体を開く
            let parent = url.path == "/" ? url : url.deletingLastPathComponent().normalizedFile
            if groups[parent] == nil { order.append(parent) }
            groups[parent, default: []].insert(url)
        }
        for parent in order {
            let items = groups[parent] ?? []
            if let existing = tabs.first(where: { $0.url.normalizedFile == parent && !$0.isSearching }) {
                existing.pendingSelection = items
                existing.reload()
                selectTab(existing.id)
            } else {
                let model = TabModel(url: parent)
                model.pendingSelection = items
                tabs.append(model)
                selectedTabID = model.id
            }
        }
    }

    /// そのタブより右にあるタブを閉じる
    func closeTabsToRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index < tabs.count - 1 else { return }
        let closing = Set(tabs[(index + 1)...].map(\.id))
        tabs.removeSubrange((index + 1)...)
        if closing.contains(selectedTabID) {
            selectedTabID = id
        }
    }

    func closeOtherTabs(_ id: UUID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        selectedTabID = id
    }

    // MARK: 移動

    /// アドレスバーなどに入力されたパスへ移動する
    /// 入力されたパスへ移動する。見つからなければエラーを出して false を返す（閉じたら onErrorClosed を呼ぶ）
    @discardableResult
    func navigate(toPath text: String, onErrorClosed: (() -> Void)? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : (tab.directory ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(expanded)
        guard tab.navigate(to: url) else {
            showError(L("「%@」が見つかりません。パスを確認して、もう一度実行してください。", trimmed), onClose: onErrorClosed)
            return false
        }
        return true
    }

    /// 項目を開く。フォルダ1つなら移動、複数フォルダは新しいタブ、ファイルは既定のアプリ
    func open(_ items: [FileItem]) {
        let folders = items.filter(\.isDirectory)
        let files = items.filter { !$0.isDirectory }
        // リンク先がないエイリアスなどは開けないので、黙って何も起きないことがないよう知らせる
        let failed = files.filter { !NSWorkspace.shared.open($0.url) }
        if let first = failed.first {
            showError(L("「%@」を開けませんでした。", first.name))
        }
        if folders.count == 1, files.isEmpty {
            tab.navigate(to: folders[0].url)
        } else {
            for folder in folders {
                newTab(url: folder.url)
            }
        }
    }

    func openSelection() {
        open(tab.selectedItems)
    }

    /// 表示中のフォルダが変わったときに呼ばれる
    func locationChanged() {
        sidebar.reveal(tab.url)
        window?.title = tab.title
        (NSApp.delegate as? AppDelegate)?.saveSession()
    }

    // MARK: ナビゲーションウィンドウ

    /// ナビゲーションウィンドウの行をクリックしたとき。フォーカスはナビゲーションウィンドウに残す
    func openSidebarRow(_ row: SidebarRow) {
        focusSidebar()
        // 「このMac」は開閉だけ。選択を移すと一覧の場所とずれる
        guard let url = row.url else { return }
        sidebar.select(row)
        if row.missing {
            confirmUnpinMissing(url)
        } else {
            tab.navigate(to: url)
        }
    }

    /// キー操作で選択が移った行のフォルダを一覧に表示する
    func showSidebarRow(_ row: SidebarRow?) {
        guard let row, let url = row.url, !row.missing else { return }
        tab.navigate(to: url)
    }

    func focusSidebar() {
        guard showSidebar else { return }
        addressEditing = false
        sidebar.hasFocus = true
    }

    private func confirmUnpinMissing(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("「%@」が見つかりません。移動または削除された可能性があります。", url.lastPathComponent)
        alert.addButton(withTitle: L("ピン留めを外す"))
        alert.addButton(withTitle: L("キャンセル"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { QuickAccess.shared.toggle(url) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func eject(_ url: URL) {
        do {
            try Volumes.eject(url)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: 通知

    func focusFileList() {
        addressEditing = false
        sidebar.hasFocus = false
        fileList?.focus()
    }

    func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func showError(_ message: String, onClose: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: L("OK"))
        if let window {
            alert.beginSheetModal(for: window) { _ in onClose?() }
        } else {
            alert.runModal()
            onClose?()
        }
    }
}

/// 再起動時に復元するウィンドウの状態
struct WindowState: Codable {
    var frame: String?
    var tabs: [String]
    var selected: Int
    var showPreview: Bool
    /// 古い保存データにはないので省略可にする
    var showSidebar: Bool?
}

enum SessionStore {
    private static let key = "session"

    static func load() -> [WindowState] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WindowState].self, from: data)) ?? []
    }

    static func save(_ states: [WindowState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
