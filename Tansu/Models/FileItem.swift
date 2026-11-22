import Foundation

enum ViewMode: String, Codable {
    case details, icons, list
}

enum SortKey: String {
    case name, modified, kind, size
}

extension URL {
    /// 同じ場所を指す URL が必ず一致するよう、表記をそろえる。
    /// フォルダの URL は取得の仕方によって末尾に「/」が付いたり付かなかったりし、
    /// /tmp や /var の配下は「/private」が付いたり付かなかったりするため
    var normalizedFile: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: false)
    }

    /// 中に入れるフォルダか。パッケージは含めず、フォルダへのシンボリックリンク（/tmp など）は含める
    func isFolder(_ values: URLResourceValues?) -> Bool {
        var values = values
        if values?.isSymbolicLink == true {
            values = try? resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        }
        return values?.isDirectory == true && values?.isPackage != true
    }
}

/// ファイル一覧の1行分
struct FileItem: Hashable, Identifiable {
    let url: URL
    /// 実際のファイル名
    let name: String
    /// システムが決める表示名（「デスクトップ」など）
    let localizedName: String
    /// 中に入れるフォルダ（.app などのパッケージは含まない）
    let isDirectory: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date?
    let kind: String
    /// Finder のカラータグ番号（1〜7）
    let tags: [Int]

    var id: URL { url }

    /// タグはここに含めない。タグの読み取りはシンボリックリンクの先をたどるため、
    /// 自動マウントの場所（/home など）へのリンクで macOS がアクセス許可を求め、応答するまで一覧の読み込みが止まる
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
        .localizedTypeDescriptionKey, .localizedNameKey,
    ]

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url.normalizedFile
        name = url.lastPathComponent
        localizedName = values.localizedName ?? url.lastPathComponent
        isDirectory = url.isFolder(values)
        isHidden = values.isHidden ?? false
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate
        kind = values.localizedTypeDescription ?? ""
        // シンボリックリンクのタグは読まない（理由は resourceKeys を参照）
        let tagNames = values.isSymbolicLink == true ? nil : (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames
        tags = Tags.indices(for: tagNames ?? [])
    }

    /// 一覧に出す名前。フォルダはシステムの表示名、ファイルは設定に応じて拡張子を隠す
    func label(showExtensions: Bool) -> String {
        if isDirectory { return localizedName }
        if showExtensions { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    static func loadDirectory(_ url: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap(FileItem.init)
    }

    /// Spotlight で見つからなければ、実際のフォルダをたどって名前を探す
    static func searchDirectory(_ url: URL, text: String, showHidden: Bool, limit: Int) -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden
            ? [.skipsPackageDescendants] : [.skipsPackageDescendants, .skipsHiddenFiles]
        guard let entries = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.localizedNameKey],
            options: options, errorHandler: { _, _ in true }) else { return [] }
        var found: [FileItem] = []
        for case let entry as URL in entries {
            if Task.isCancelled || found.count >= limit { break }
            let name = (try? entry.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            guard entry.lastPathComponent.localizedStandardContains(text) ||
                  name?.localizedStandardContains(text) == true else { continue }
            if let item = FileItem(url: entry) { found.append(item) }
        }
        return found
    }

    /// フォルダを常に先にして並べ替える
    static func sorted(_ items: [FileItem], key: SortKey, ascending: Bool) -> [FileItem] {
        func byName(_ a: FileItem, _ b: FileItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func ordered(_ a: FileItem, _ b: FileItem) -> Bool {
            switch key {
            case .name:
                return byName(a, b)
            case .modified:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                return x == y ? byName(a, b) : x < y
            case .kind:
                let result = a.kind.localizedStandardCompare(b.kind)
                return result == .orderedSame ? byName(a, b) : result == .orderedAscending
            case .size:
                return a.size == b.size ? byName(a, b) : a.size < b.size
            }
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return ascending ? ordered(a, b) : ordered(b, a)
        }
    }
}
