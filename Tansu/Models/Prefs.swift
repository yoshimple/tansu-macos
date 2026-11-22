import Foundation

extension Notification.Name {
    static let prefsChanged = Notification.Name("TansuPrefsChanged")
    static let quickAccessChanged = Notification.Name("TansuQuickAccessChanged")
}

/// アプリ全体の表示設定（UserDefaults に保存）
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "showHidden"); notify() }
    }
    @Published var showExtensions: Bool {
        didSet { defaults.set(showExtensions, forKey: "showExtensions"); notify() }
    }
    /// ファイル一覧のフォルダまで、ナビゲーションウィンドウのツリーを開く
    @Published var expandToOpenFolder: Bool {
        didSet { defaults.set(expandToOpenFolder, forKey: "expandToOpenFolder"); notify() }
    }

    private init() {
        showHidden = defaults.bool(forKey: "showHidden")
        showExtensions = defaults.object(forKey: "showExtensions") as? Bool ?? true
        expandToOpenFolder = defaults.object(forKey: "expandToOpenFolder") as? Bool ?? true
    }

    private func notify() {
        NotificationCenter.default.post(name: .prefsChanged, object: nil)
    }

    // MARK: フォルダごとの表示形式

    func viewMode(for url: URL) -> ViewMode {
        let modes = defaults.dictionary(forKey: "folderViewModes") as? [String: String] ?? [:]
        return modes[url.path].flatMap(ViewMode.init(rawValue:)) ?? .details
    }

    func setViewMode(_ mode: ViewMode, for url: URL) {
        var modes = defaults.dictionary(forKey: "folderViewModes") as? [String: String] ?? [:]
        modes[url.path] = mode == .details ? nil : mode.rawValue
        defaults.set(modes, forKey: "folderViewModes")
    }
}

/// クイックアクセスにピン留めしたフォルダ
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()
    private(set) var urls: [URL]

    private init() {
        if let paths = UserDefaults.standard.stringArray(forKey: "quickAccess") {
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            let dirs: [FileManager.SearchPathDirectory] = [
                .desktopDirectory, .downloadsDirectory, .documentDirectory, .picturesDirectory,
            ]
            urls = dirs.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
        }
    }

    func isPinned(_ url: URL) -> Bool {
        urls.contains { $0.path == url.path }
    }

    func toggle(_ url: URL) {
        if isPinned(url) {
            urls.removeAll { $0.path == url.path }
        } else {
            urls.append(url.standardizedFileURL)
        }
        save()
    }

    /// 指定した位置にピン留めする。ピン留め済みのものは、その位置へ並べ替える
    func insert(_ newURLs: [URL], at index: Int) {
        var index = index
        for url in newURLs.map(\.standardizedFileURL) {
            if let existing = urls.firstIndex(where: { $0.path == url.path }) {
                urls.remove(at: existing)
                if existing < index { index -= 1 }
            }
            urls.insert(url, at: min(max(index, 0), urls.count))
            index += 1
        }
        save()
    }

    func index(of url: URL) -> Int? {
        urls.firstIndex { $0.path == url.path }
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: "quickAccess")
        NotificationCenter.default.post(name: .quickAccessChanged, object: nil)
    }
}
