import AppKit

/// ナビゲーションウィンドウに表示する1行
struct SidebarRow: Identifiable {
    let id: String
    /// nil は「このMac」の見出し行
    let url: URL?
    let title: String
    let symbol: String
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    var ejectable = false
    var pinned = false
    /// ピン留めしたフォルダが見つからない
    var missing = false
    /// 行の上に区切り線を入れる
    var separatorBefore = false
}

/// ナビゲーションウィンドウのツリー。展開状態を持ち、表示する行の並びを作る
@MainActor
final class SidebarModel: ObservableObject {
    @Published private(set) var rows: [SidebarRow] = []
    @Published private(set) var selectedID: String?
    /// キーボード操作の対象になっているか
    @Published var hasFocus = false
    /// 値が変わると、選択中の行が見えるようにスクロールする
    @Published private(set) var revealRequest = 0

    private static let thisMacID = "thismac"
    private static let recentsID = "recents"
    static let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    private static let applicationsURL = URL(fileURLWithPath: "/Applications")
    /// 起動ディスク直下のシステム用の空フォルダ。/.nofollow は表示名が「Macintosh HD」になり、ディスクと区別できない
    nonisolated private static let systemFolders: Set<String> = [".nofollow", ".resolve", ".vol"]
    private var expanded: Set<String> = [thisMacID]
    /// 一覧の場所に合わせて自動で開いた行。別の場所へ移ると閉じる。手で開閉した行は含めない
    private var autoExpanded: Set<String> = []
    private var subfolderCache: [String: [URL]] = [:]
    /// 中身を読み込み中のフォルダ
    private var loading: Set<String> = []
    /// キャッシュを捨てるたびに増やす。捨てる前に始めた読み込みの結果は使わない
    private var cacheGeneration = 0
    private var current: URL?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers = [
            center.addObserver(forName: .quickAccessChanged, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .prefsChanged, object: nil, queue: .main, using: refresh),
        ]
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: refresh))
        }
        rebuild()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: 操作

    func toggle(_ row: SidebarRow) {
        autoExpanded.remove(row.id)
        if expanded.contains(row.id) {
            expanded.remove(row.id)
        } else {
            expanded.insert(row.id)
        }
        rebuild()
    }

    func expand(_ row: SidebarRow) {
        guard row.expandable, !expanded.contains(row.id) else { return }
        autoExpanded.remove(row.id)
        expanded.insert(row.id)
        rebuild()
    }

    /// 行を選択状態にする。続けてそのフォルダへ移動したとき、選んだ行のツリーで選択を保つ
    func select(_ row: SidebarRow) {
        selectedID = row.id
    }

    // MARK: キー操作。移動先の行を返す

    /// 上下の行へ選択を移す
    func moveSelection(by step: Int) -> SidebarRow? {
        guard !rows.isEmpty else { return nil }
        let index = rows.firstIndex { $0.id == selectedID }.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        let row = rows[min(max(index, 0), rows.count - 1)]
        selectedID = row.id
        return row
    }

    /// 閉じていれば開き、開いていれば最初の子へ移る
    func moveRight() -> SidebarRow? {
        guard let index = rows.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let row = rows[index]
        guard row.expandable else { return nil }
        if !row.expanded {
            toggle(row)
            return nil
        }
        guard index + 1 < rows.count, rows[index + 1].depth > row.depth else { return nil }
        selectedID = rows[index + 1].id
        return rows[index + 1]
    }

    /// 開いていれば閉じ、閉じていれば親の行へ移る
    func moveLeft() -> SidebarRow? {
        guard let index = rows.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let row = rows[index]
        if row.expanded {
            toggle(row)
            return nil
        }
        guard let parent = rows[..<index].last(where: { $0.depth < row.depth }) else { return nil }
        selectedID = parent.id
        return parent
    }

    /// 一覧で開いているフォルダまでツリーを展開し、その行を選択状態にする。
    /// 「開いているフォルダーまで展開」がオフのときは、開閉と選択を変えない
    func reveal(_ url: URL) {
        current = url
        guard Prefs.shared.expandToOpenFolder else {
            rebuild()
            return
        }
        if url == TabModel.recentsURL {
            selectedID = Self.recentsID
            autoExpand([])
            rebuild()
            return
        }
        let path = url.standardizedFileURL.path
        // 選択中の行がそのフォルダを含むなら、その行の起点のツリーで選択を保つ。
        // なければ、そのフォルダを含む起点のうち最も深いものを選ぶ。
        // 起動ディスク（/）はすべてを含むので、ディスクの行そのものは選択を保つ対象にしない
        let candidates = roots().filter { Self.contains(root: $0.path, path: path) }
        let selectedParts = selectedID?.split(separator: "|", maxSplits: 1).map(String.init) ?? []
        let kept = candidates.first { root in
            guard root.id == selectedParts.first else { return false }
            let selectedPath = selectedParts.count > 1 ? selectedParts[1] : root.path
            return selectedPath != "/" && Self.contains(root: selectedPath, path: path)
        }
        let match = kept ?? candidates.max { $0.path.count < $1.path.count }
        guard let match else {
            selectedID = nil
            autoExpand([])
            rebuild()
            return
        }
        // その行を表示するのに開く必要がある行
        var needed: Set<String> = []
        if match.id.hasPrefix("vol:") {
            needed.insert(Self.thisMacID)
        }
        if match.path == path || !match.expandable {
            selectedID = match.id
        } else {
            needed.insert(match.id)
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count > match.path.count {
                needed.insert(match.id + "|" + ancestor)
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            selectedID = match.id + "|" + path
        }
        autoExpand(needed)
        rebuild()
        revealRequest += 1
    }

    /// 前の場所のために自動で開いた行のうち、今は要らないものを閉じてから、必要な行を開く
    private func autoExpand(_ needed: Set<String>) {
        expanded.subtract(autoExpanded.subtracting(needed))
        let newlyOpened = needed.subtracting(expanded)
        autoExpanded = autoExpanded.intersection(needed).union(newlyOpened)
        expanded.formUnion(needed)
    }

    /// フォルダの中身が変わったときに呼ぶ
    func invalidate(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        guard subfolderCache.removeValue(forKey: path) != nil || loading.contains(path) else { return }
        cacheGeneration += 1
        rebuild()
    }

    private func refresh() {
        subfolderCache.removeAll()
        cacheGeneration += 1
        if let current {
            reveal(current)
        } else {
            rebuild()
        }
    }

    // MARK: 行の組み立て

    private struct Root {
        let id: String
        let url: URL
        var expandable = true
        var path: String { url.standardizedFileURL.path }
    }

    private func roots() -> [Root] {
        var result = [Root(id: "home", url: FileManager.default.homeDirectoryForCurrentUser)]
        result += QuickAccess.shared.urls.map { Root(id: "pin:" + $0.path, url: $0) }
        if let iCloud = Volumes.iCloudDrive {
            result.append(Root(id: "icloud", url: iCloud))
        }
        result += Volumes.cloudStorage.map { Root(id: "cloud:" + $0.path, url: $0) }
        result.append(Root(id: "apps", url: Self.applicationsURL))
        result += Volumes.list().map { Root(id: "vol:" + $0.url.path, url: $0.url) }
        result.append(Root(id: "trash", url: Self.trashURL, expandable: false))
        return result
    }

    private static func contains(root: String, path: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    private func rebuild() {
        var result: [SidebarRow] = []

        /// 中を読んだことがあり、サブフォルダが1つもない行は開けないものとして「>」を出さない。
        /// 開いていない行の中身は読まない（読むまでは開けるものとして扱う）
        func hasSubfolders(_ url: URL, expanded isExpanded: Bool) -> Bool {
            let known = isExpanded ? subfolders(of: url) : subfolderCache[url.standardizedFileURL.path]
            // 読み込み中は開けるものとして扱う
            return known.map { !$0.isEmpty } ?? true
        }

        func appendChildren(of url: URL, rootID: String, path: String, depth: Int) {
            for child in subfolders(of: url) ?? [] {
                // 列挙された URL に /private が付いても、表示中のツリーの親パスを引き継ぐ
                let childPath = (path as NSString).appendingPathComponent(child.lastPathComponent)
                let id = rootID + "|" + childPath
                let expandable = hasSubfolders(child, expanded: expanded.contains(id))
                let isExpanded = expandable && expanded.contains(id)
                result.append(SidebarRow(
                    id: id, url: child, title: FileManager.default.displayName(atPath: child.path),
                    symbol: "folder.fill", depth: depth, expandable: expandable, expanded: isExpanded))
                if isExpanded {
                    appendChildren(of: child, rootID: rootID, path: childPath, depth: depth + 1)
                }
            }
        }

        func appendRoot(id: String, url: URL, title: String, symbol: String, depth: Int = 0, expandable: Bool = true,
                        ejectable: Bool = false, pinned: Bool = false, missing: Bool = false, separatorBefore: Bool = false) {
            let expandable = expandable && hasSubfolders(url, expanded: expanded.contains(id))
            let isExpanded = expandable && expanded.contains(id)
            result.append(SidebarRow(
                id: id, url: url, title: title, symbol: symbol, depth: depth, expandable: expandable,
                expanded: isExpanded, ejectable: ejectable, pinned: pinned, missing: missing, separatorBefore: separatorBefore))
            if isExpanded {
                appendChildren(of: url, rootID: id, path: url.standardizedFileURL.path, depth: depth + 1)
            }
        }

        appendRoot(id: Self.recentsID, url: TabModel.recentsURL, title: L("最近使用した項目"), symbol: "clock.fill",
                   expandable: false)
        appendRoot(id: "home", url: FileManager.default.homeDirectoryForCurrentUser, title: L("ホーム"), symbol: "house.fill")

        for (index, url) in QuickAccess.shared.urls.enumerated() {
            let missing = !FileManager.default.fileExists(atPath: url.path)
            appendRoot(id: "pin:" + url.path, url: url, title: FileManager.default.displayName(atPath: url.path),
                       symbol: Self.symbol(forPinned: url), expandable: !missing, pinned: true, missing: missing,
                       separatorBefore: index == 0)
        }

        if let iCloud = Volumes.iCloudDrive {
            appendRoot(id: "icloud", url: iCloud, title: L("iCloud Drive"), symbol: "icloud.fill", separatorBefore: true)
        }
        let clouds = Volumes.cloudStorage
        for (index, url) in clouds.enumerated() {
            appendRoot(id: "cloud:" + url.path, url: url, title: Volumes.cloudStorageName(url), symbol: "cloud.fill",
                       separatorBefore: index == 0 && Volumes.iCloudDrive == nil)
        }
        appendRoot(id: "apps", url: Self.applicationsURL, title: FileManager.default.displayName(atPath: Self.applicationsURL.path),
                   symbol: "square.grid.2x2.fill", separatorBefore: Volumes.iCloudDrive == nil && clouds.isEmpty)

        let thisMacExpanded = expanded.contains(Self.thisMacID)
        result.append(SidebarRow(
            id: Self.thisMacID, url: nil, title: L("このMac"), symbol: "desktopcomputer", depth: 0,
            expandable: true, expanded: thisMacExpanded, separatorBefore: true))
        if thisMacExpanded {
            for volume in Volumes.list() {
                appendRoot(id: "vol:" + volume.url.path, url: volume.url, title: volume.name,
                           symbol: volume.ejectable ? "externaldrive.fill" : "internaldrive.fill",
                           depth: 1, ejectable: volume.ejectable)
            }
        }
        appendRoot(id: "trash", url: Self.trashURL, title: L("ゴミ箱"), symbol: "trash.fill",
                   expandable: false, separatorBefore: true)
        rows = result
    }

    /// サブフォルダの一覧。まだ読んでいなければ裏で読み始めて nil を返し、読み終えたら行を作り直す。
    /// 大きなフォルダやネットワーク上のフォルダを開いても画面が止まらないようにする
    private func subfolders(of url: URL) -> [URL]? {
        if let cached = subfolderCache[url.standardizedFileURL.path] { return cached }
        load(url)
        return nil
    }

    private func load(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard loading.insert(path).inserted else { return }
        let showHidden = Prefs.shared.showHidden
        let generation = cacheGeneration
        Task { [weak self] in
            let folders = await Task.detached(priority: .userInitiated) {
                Self.readSubfolders(of: url, showHidden: showHidden)
            }.value
            guard let self else { return }
            loading.remove(path)
            // 読んでいる間に中身が変わった。作り直すと新しく読み直す
            guard generation == cacheGeneration else {
                rebuild()
                return
            }
            subfolderCache[path] = folders
            let selected = selectedID
            let wasShown = rows.contains { $0.id == selected }
            rebuild()
            // 一覧で開いている場所の行が、読み込みを待って初めて現れたときはそこまでスクロールする
            if !wasShown, rows.contains(where: { $0.id == selected }) {
                revealRequest += 1
            }
        }
    }

    nonisolated private static func readSubfolders(of url: URL, showHidden: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return contents.filter { child in
            // /.nofollow の path は末尾に「/」が付くことがあるので、名前で比べる
            !(url.path == "/" && systemFolders.contains(child.lastPathComponent)) && child.isFolder(try? child.resourceValues(forKeys: Set(keys)))
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func symbol(forPinned url: URL) -> String {
        let fm = FileManager.default
        func path(_ directory: FileManager.SearchPathDirectory) -> String? {
            fm.urls(for: directory, in: .userDomainMask).first?.path
        }
        switch url.path {
        case path(.desktopDirectory): return "menubar.dock.rectangle"
        case path(.downloadsDirectory): return "arrow.down.circle.fill"
        case path(.documentDirectory): return "doc.fill"
        case path(.picturesDirectory): return "photo.fill"
        case path(.musicDirectory): return "music.note"
        case path(.moviesDirectory): return "film"
        default: return "folder.fill"
        }
    }
}
