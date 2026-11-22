import AppKit

/// 同名の項目があるときの選択
enum ConflictChoice {
    case replace, skip, keepBoth, cancel
}

struct TransferResult {
    /// 完了した項目（元の場所と新しい場所）
    var completed: [(source: URL, destination: URL)] = []
    /// 「置き換える」でゴミ箱へ移した既存の項目（元の場所とゴミ箱内の場所）
    var replaced: [(original: URL, trashed: URL)] = []
    var failures: [(url: URL, message: String)] = []
    var cancelled = false
}

struct TrashResult {
    var trashed: [(original: URL, trashed: URL)] = []
    var failures: [(url: URL, message: String)] = []
    var cancelled = false
}

struct FileOpsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// ファイル操作の本体。UI に依存しないので単体テストできる
enum FileOps {
    private static var fm: FileManager { .default }

    // MARK: 名前

    /// 同名の項目があれば「名前 (2).txt」のように番号を付けて、空いている場所を返す
    static func uniqueURL(for url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : (url.lastPathComponent as NSString).deletingPathExtension
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// 同じフォルダへコピーするときの名前（「名前 - コピー.txt」）
    static func copyURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : (url.lastPathComponent as NSString).deletingPathExtension
        let name = stem + L(" - コピー") + (ext.isEmpty ? "" : "." + ext)
        return uniqueURL(for: url.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// url が ancestor の中（子孫）にあるか
    static func isInside(_ url: URL, _ ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = ancestor.standardizedFileURL.path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." {
            throw FileOpsError(message: L("「%@」という名前は使えません。", name))
        }
        if name.contains("/") || name.contains(":") {
            throw FileOpsError(message: L("ファイル名には「/」と「:」を使えません。"))
        }
    }

    // MARK: 名前変更と新規作成

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        try validateName(newName)
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        // 大文字と小文字だけの変更は、同じファイルを指すので許可する
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if fm.fileExists(atPath: destination.path), !caseOnly {
            throw FileOpsError(message: L("この場所には「%@」という名前の項目が既にあります。", newName))
        }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    static func createFolder(in directory: URL, name: String) throws -> URL {
        let url = uniqueURL(for: directory.appendingPathComponent(name))
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func createFile(in directory: URL, name: String) throws -> URL {
        let url = uniqueURL(for: directory.appendingPathComponent(name))
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw FileOpsError(message: L("「%@」を作成できませんでした。", url.lastPathComponent))
        }
        return url
    }

    // MARK: ゴミ箱

    /// ゴミ箱へ移動する。完全には削除しない
    static func trash(_ urls: [URL], progress: (Int, Int) -> Void = { _, _ in }) -> TrashResult {
        var result = TrashResult()
        for (index, url) in urls.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            do {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed = trashed as URL? {
                    result.trashed.append((url, trashed))
                }
            } catch {
                result.failures.append((url, error.localizedDescription))
            }
            progress(index + 1, urls.count)
        }
        return result
    }

    // MARK: コピーと移動

    /// sources を directory へコピーまたは移動する。
    /// 同名の項目があれば resolve に尋ねる。「置き換える」は既存の項目をゴミ箱へ移してから行う
    static func transfer(_ sources: [URL], to directory: URL, move: Bool,
                         resolve: (URL) async -> ConflictChoice,
                         progress: (Int, Int) -> Void = { _, _ in }) async -> TransferResult {
        var result = TransferResult()
        let total = sources.reduce(0) { $0 + countItems($1) }
        var done = 0
        var lastReport = Date.distantPast
        func tick() {
            done += 1
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.05 || done >= total {
                lastReport = now
                progress(done, total)
            }
        }

        for source in sources {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            // 置き換えでゴミ箱へ移した既存の項目。この項目が完了しなければ元に戻す
            var trashedExisting: URL?
            // 別ボリュームへの移動で、コピーまで終わった。以降の失敗では宛先を消さない
            var copied = false
            let sameItem = destination.standardizedFileURL.path == source.standardizedFileURL.path
            do {
                if sameItem {
                    // 同じフォルダへの移動は何もしない。コピーは複製を作る
                    if move { continue }
                    destination = copyURL(for: source)
                } else if isInside(directory, source) || directory.standardizedFileURL.path == source.standardizedFileURL.path {
                    throw FileOpsError(message: L("受け側のフォルダーは、送り側フォルダーのサブフォルダーです。"))
                } else if fm.fileExists(atPath: destination.path) {
                    let choice = await resolve(destination)
                    try Task.checkCancellation()
                    switch choice {
                    case .cancel:
                        throw CancellationError()
                    case .skip:
                        continue
                    case .keepBoth:
                        destination = uniqueURL(for: destination)
                    case .replace:
                        var trashed: NSURL?
                        try fm.trashItem(at: destination, resultingItemURL: &trashed)
                        trashedExisting = trashed as URL?
                    }
                }
                if move, Volumes.sameVolume(source, directory) {
                    // 移動した後は元がないので、件数は先に数える
                    let count = countItems(source)
                    try fm.moveItem(at: source, to: destination)
                    for _ in 0..<count { tick() }
                } else {
                    try copyTree(from: source, to: destination, tick: tick)
                    if move {
                        copied = true
                        try fm.removeItem(at: source)
                    }
                }
                result.completed.append((source, destination))
                if let trashedExisting { result.replaced.append((destination, trashedExisting)) }
            } catch is CancellationError {
                restoreReplaced(trashedExisting, to: destination)
                result.cancelled = true
                break
            } catch {
                if !copied { restoreReplaced(trashedExisting, to: destination) }
                result.failures.append((source, error.localizedDescription))
            }
        }
        return result
    }

    /// 置き換えの途中で失敗したとき、途中までのコピーを消して既存の項目をゴミ箱から戻す。
    /// 既存の項目をゴミ箱へ移した後なので、宛先にあるのはこの操作で作ったものだけ
    private static func restoreReplaced(_ trashed: URL?, to destination: URL) {
        guard let trashed else { return }
        try? fm.removeItem(at: destination)
        try? fm.moveItem(at: trashed, to: destination)
    }

    /// コピー／移動を取り消す。コピーした項目はゴミ箱へ、移動した項目は元の場所へ戻し、
    /// 置き換えた既存の項目をゴミ箱から元の場所へ戻す
    static func undoTransfer(_ result: TransferResult, move: Bool) throws {
        for pair in result.completed {
            if move {
                try fm.moveItem(at: pair.destination, to: pair.source)
            } else {
                try fm.trashItem(at: pair.destination, resultingItemURL: nil)
            }
        }
        for item in result.replaced {
            try fm.moveItem(at: item.trashed, to: item.original)
        }
    }

    /// フォルダの中身を1件ずつコピーする。途中でキャンセルできる
    static func copyTree(from source: URL, to destination: URL, tick: () -> Void) throws {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(from: child, to: destination.appendingPathComponent(child.lastPathComponent), tick: tick)
            }
            if let attributes = try? fm.attributesOfItem(atPath: source.path) {
                let kept = attributes.filter { [.modificationDate, .creationDate, .posixPermissions].contains($0.key) }
                try? fm.setAttributes(kept, ofItemAtPath: destination.path)
            }
        } else {
            try fm.copyItem(at: source, to: destination)
        }
        tick()
    }

    /// 進捗の分母に使う件数（フォルダは中身も数える）
    static func countItems(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return 1 }
        var count = 1
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for _ in enumerator { count += 1 }
        }
        return count
    }
}

enum DropOperation {
    case copy, move
}

/// ドラッグ＆ドロップで行う操作の判定（Windows と同じ規則）
enum DropLogic {
    /// コピーを強制するか。Option キーを押している間、AppKit はドラッグ元が許可する操作をコピーだけに絞る。
    /// ドラッグ元が移動を許可していない場合（ほかのアプリからのドラッグなど）もコピーにする
    static func forcesCopy(sourceMask: NSDragOperation, optionPressed: Bool) -> Bool {
        optionPressed || !sourceMask.contains(.move)
    }

    /// 同じボリューム内は移動、別のボリュームへはコピー。forceCopy（Option キー）なら常にコピー。
    /// 自分自身や自分の中へのドロップ、同じフォルダ内での移動は nil（受け付けない）
    static func operation(sources: [URL], target: URL, forceCopy: Bool,
                          sameVolume: (URL, URL) -> Bool = Volumes.sameVolume) -> DropOperation? {
        guard !sources.isEmpty else { return nil }
        let targetPath = target.standardizedFileURL.path
        for source in sources {
            if source.standardizedFileURL.path == targetPath || FileOps.isInside(target, source) {
                return nil
            }
        }
        let move = !forceCopy && sources.allSatisfy { sameVolume($0, target) }
        let alreadyThere = sources.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }
        if move && alreadyThere { return nil }
        return move ? .move : .copy
    }
}
