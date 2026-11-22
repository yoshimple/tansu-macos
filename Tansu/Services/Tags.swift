import AppKit

/// Finder のカラータグ
enum Tags {
    /// 添字がラベル番号。0 は「なし」
    static let names: [String] = NSWorkspace.shared.fileLabels
    static let colors: [NSColor] = NSWorkspace.shared.fileLabelColors

    static func indices(for tagNames: [String]) -> [Int] {
        tagNames.compactMap { name in
            guard let index = names.firstIndex(of: name), index > 0 else { return nil }
            return index
        }
    }

    /// 全項目に付いていれば外し、そうでなければ全項目に付ける
    static func toggle(_ index: Int, on urls: [URL]) {
        guard names.indices.contains(index), index > 0 else { return }
        let name = names[index]
        let current = urls.map { (try? $0.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] }
        let allHave = current.allSatisfy { $0.contains(name) }
        for (url, tags) in zip(urls, current) {
            var updated = tags.filter { $0 != name }
            if !allHave { updated.append(name) }
            try? (url as NSURL).setResourceValue(updated, forKey: .tagNamesKey)
        }
    }
}
