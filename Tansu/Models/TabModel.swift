import AppKit

/// タブ1つ分の状態（開いているフォルダ、一覧、選択、履歴）
@MainActor
final class TabModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var url: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var viewMode: ViewMode
    @Published private(set) var sortKey: SortKey = .name
    @Published private(set) var sortAscending = true
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// Git リポジトリ内のフォルダを開いているときだけ入る
    @Published private(set) var git: GitInfo?
    /// 検索ボックスの入力。空でなければ、表示中のフォルダ以下の検索結果を表示する
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue, !isChangingFolder else { return }
            if isSearching {
                scheduleSearch()
            } else {
                // 検索の解除はすぐ一覧に戻す。待つと、その間「このフォルダーは空です」が見えてしまう
                searchWork?.cancel()
                selection = []
                reload()
            }
        }
    }

    /// フォルダの移動中。移動先を読み込むので、検索の解除による読み込みはしない
    private var isChangingFolder = false

    /// items を差し替えるたびに増やす。一覧ビューが再読み込みの要否を判断する
    private(set) var itemsVersion = 0
    /// 次の読み込み後に選択する項目
    var pendingSelection: Set<URL>?
    /// 次の読み込み後に名前変更を始める項目
    var pendingRename: URL?

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var loadTask: Task<Void, Never>?
    private let watcher = DirectoryWatcher()
    private var reloadWork: DispatchWorkItem?
    private var prefsObserver: NSObjectProtocol?
    private var gitTask: Task<Void, Never>?
    private let search = SpotlightSearch()
    private var searchWork: DispatchWorkItem?

    /// 「最近使用した項目」を表す場所。実在するフォルダではない
    static let recentsURL = URL(string: "tansu:recents")!

    /// 「最近使用した項目」では、使った日時の新しい順に並べる。並べ替えを選ぶと解除する
    private(set) var usesQueryOrder = false

    init(url: URL) {
        let start = Self.existingDirectory(url)
        self.url = start
        usesQueryOrder = start == Self.recentsURL
        viewMode = Prefs.shared.viewMode(for: start)
        prefsObserver = NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        startWatching()
        reload()
    }

    deinit {
        loadTask?.cancel()
        if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) }
    }

    /// 存在しない場所が渡されたら、存在する親まで遡る
    private static func existingDirectory(_ url: URL) -> URL {
        if url == recentsURL { return url }
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isRecents: Bool {
        url == Self.recentsURL
    }

    /// 表示中のフォルダ。「最近使用した項目」では nil（貼り付けや新規作成の先がない）
    var directory: URL? {
        isRecents ? nil : url
    }

    /// 表示中のフォルダの名前
    var folderName: String {
        isRecents ? L("最近使用した項目") : FileManager.default.displayName(atPath: url.path)
    }

    var title: String {
        isSearching ? L("「%@」の検索結果", searchText) : folderName
    }

    var selectedItems: [FileItem] {
        selection.isEmpty ? [] : items.filter { selection.contains($0.url) }
    }

    // MARK: 移動

    /// 検索結果の表示中は、検索を解除して元のフォルダへ戻れる
    var canGoBack: Bool { !backStack.isEmpty || isSearching }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !isRecents && url.path != "/" }

    /// フォルダへ移動する。ファイルなら既定のアプリで開く。存在しなければ false
    @discardableResult
    func navigate(to newURL: URL) -> Bool {
        let target = newURL.standardizedFileURL
        if target == Self.recentsURL, target != url {
            backStack.append(url)
            forwardStack.removeAll()
            show(target)
            return true
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else {
            NSWorkspace.shared.open(target)
            return true
        }
        if target == url {
            reload()
            return true
        }
        backStack.append(url)
        forwardStack.removeAll()
        show(target)
        return true
    }

    func goBack() {
        if isSearching {
            searchText = ""
            return
        }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        show(previous, selecting: url)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        show(next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = url
        backStack.append(url)
        forwardStack.removeAll()
        show(url.deletingLastPathComponent(), selecting: child)
    }

    private func show(_ target: URL, selecting: URL? = nil) {
        searchWork?.cancel()
        search.stop()
        if !searchText.isEmpty {
            isChangingFolder = true
            searchText = ""
            isChangingFolder = false
        }
        url = Self.existingDirectory(target)
        usesQueryOrder = isRecents
        viewMode = Prefs.shared.viewMode(for: url)
        items = []
        itemsVersion += 1
        selection = []
        pendingSelection = selecting.map { [$0] }
        pendingRename = nil
        git = nil
        startWatching()
        reload()
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        Prefs.shared.setViewMode(mode, for: url)
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        guard key != sortKey || ascending != sortAscending || usesQueryOrder else { return }
        usesQueryOrder = false
        sortKey = key
        sortAscending = ascending
        items = FileItem.sorted(items, key: key, ascending: ascending)
        itemsVersion += 1
    }

    // MARK: 読み込み

    private func startWatching() {
        // 「最近使用した項目」は Spotlight の更新通知で読み込み直す
        guard !isRecents else {
            watcher.stop()
            return
        }
        watcher.watch(url) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    /// 連続した変更をまとめてから読み込み直す
    private func scheduleReload() {
        guard !isSearching else { return }
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func reload() {
        loadTask?.cancel()
        if isRecents {
            runRecents()
            return
        }
        if isSearching {
            runSearch()
            return
        }
        search.stop()
        let target = url
        let showHidden = Prefs.shared.showHidden
        let key = sortKey, ascending = sortAscending
        isLoading = items.isEmpty
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { FileItem.sorted(try FileItem.loadDirectory(target, showHidden: showHidden), key: key, ascending: ascending) }
            }.value
            guard let self, !Task.isCancelled, self.url == target else { return }
            self.isLoading = false
            switch result {
            case .success(let loaded):
                self.loadError = nil
                self.apply(loaded)
                self.refreshGit()
            case .failure(let error):
                self.loadError = error.localizedDescription
                self.apply([])
            }
        }
    }

    // MARK: Git

    /// ブランチ名と変更状態を取り直す。リポジトリ外、または AI 連携の表示を切っているときは何も表示しない
    private func refreshGit() {
        gitTask?.cancel()
        guard SettingsStore.shared.aiEnabled, !isRecents else {
            if git != nil { git = nil }
            return
        }
        let target = url
        gitTask = Task { [weak self] in
            let info = await Task.detached(priority: .utility) { Git.info(for: target) }.value
            guard let self, !Task.isCancelled, self.url == target else { return }
            if self.git != info { self.git = info }
        }
    }

    // MARK: 検索

    /// 入力が止まってから検索を始める
    private func scheduleSearch() {
        searchWork?.cancel()
        loadTask?.cancel()
        search.stop()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.items = []
            self.itemsVersion += 1
            self.selection = []
            self.reload()
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runSearch() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        let scope = url
        let showHidden = Prefs.shared.showHidden
        isLoading = true
        loadError = nil
        search.start(text: text, scope: scope) { [weak self] urls, finished in
            guard let self else { return }
            let key = self.sortKey, ascending = self.sortAscending
            self.loadTask?.cancel()
            self.loadTask = Task { [weak self] in
                let work = Task.detached(priority: .userInitiated) {
                    var found = urls.compactMap(FileItem.init).filter { showHidden || !$0.isHidden }
                    if finished, found.isEmpty, !Task.isCancelled {
                        found = FileItem.searchDirectory(scope, text: text, showHidden: showHidden, limit: SpotlightSearch.resultLimit)
                    }
                    return FileItem.sorted(found, key: key, ascending: ascending)
                }
                let found = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                guard let self, !Task.isCancelled, self.isSearching, self.url == scope else { return }
                if finished { self.isLoading = false }
                self.apply(found)
            }
        }
    }

    // MARK: 最近使用した項目

    /// Spotlight の最終使用日をもとに一覧を作る。検索ボックスの入力は名前の絞り込みに使う
    private func runRecents() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        isLoading = items.isEmpty
        loadError = nil
        search.startRecents { [weak self] urls, finished in
            guard let self else { return }
            let key = self.sortKey, ascending = self.sortAscending, keepsOrder = self.usesQueryOrder
            self.loadTask?.cancel()
            self.loadTask = Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    var items = urls.compactMap(FileItem.init)
                    if !text.isEmpty {
                        items = items.filter { $0.name.localizedStandardContains(text) }
                    }
                    return keepsOrder ? items : FileItem.sorted(items, key: key, ascending: ascending)
                }.value
                guard let self, !Task.isCancelled, self.isRecents else { return }
                if finished { self.isLoading = false }
                self.apply(found)
            }
        }
    }

    private func apply(_ loaded: [FileItem]) {
        let existing = Set(loaded.map(\.url))
        if loaded != items {
            itemsVersion += 1
        }
        if let pending = pendingSelection.map({ Set($0.map(\.normalizedFile)) }), !pending.isDisjoint(with: existing) {
            selection = pending.intersection(existing)
            pendingSelection = nil
        } else if !selection.isSubset(of: existing) {
            selection = selection.intersection(existing)
        }
        // 変化がなくても代入して、一覧ビューに同期の機会を与える（pendingRename の処理など）
        items = loaded
    }
}
