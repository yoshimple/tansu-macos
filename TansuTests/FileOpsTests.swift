import AppKit
import XCTest
@testable import Tansu

final class FileOpsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("TansuTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: 名前

    func testUniqueURLAddsNumber() throws {
        let url = try file("a.txt")
        XCTAssertEqual(FileOps.uniqueURL(for: url).lastPathComponent, "a (2).txt")
        try file("a (2).txt")
        XCTAssertEqual(FileOps.uniqueURL(for: url).lastPathComponent, "a (3).txt")
        XCTAssertEqual(FileOps.uniqueURL(for: root.appendingPathComponent("new.txt")).lastPathComponent, "new.txt")
    }

    func testUniqueURLWithoutExtension() throws {
        let dir = try folder("docs")
        XCTAssertEqual(FileOps.uniqueURL(for: dir).lastPathComponent, "docs (2)")
    }

    func testIsInside() {
        let a = URL(fileURLWithPath: "/tmp/a")
        XCTAssertTrue(FileOps.isInside(URL(fileURLWithPath: "/tmp/a/b/c"), a))
        XCTAssertFalse(FileOps.isInside(a, a))
        XCTAssertFalse(FileOps.isInside(URL(fileURLWithPath: "/tmp/ab"), a))
    }

    // MARK: 名前変更と新規作成

    func testRename() throws {
        let url = try file("a.txt", "hello")
        let renamed = try FileOps.rename(url, to: "b.txt")
        XCTAssertEqual(renamed.lastPathComponent, "b.txt")
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertEqual(read(renamed), "hello")
    }

    func testRenameRefusesExistingName() throws {
        let a = try file("a.txt", "A")
        let b = try file("b.txt", "B")
        XCTAssertThrowsError(try FileOps.rename(a, to: "b.txt"))
        XCTAssertEqual(read(a), "A")
        XCTAssertEqual(read(b), "B")
    }

    func testRenameRefusesInvalidName() throws {
        let a = try file("a.txt")
        XCTAssertThrowsError(try FileOps.rename(a, to: "x/y.txt"))
        XCTAssertThrowsError(try FileOps.rename(a, to: ""))
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    func testCreateFolderAndFileUseUniqueNames() throws {
        let first = try FileOps.createFolder(in: root, name: "新しいフォルダー")
        let second = try FileOps.createFolder(in: root, name: "新しいフォルダー")
        XCTAssertEqual(first.lastPathComponent, "新しいフォルダー")
        XCTAssertEqual(second.lastPathComponent, "新しいフォルダー (2)")
        let text = try FileOps.createFile(in: root, name: "メモ.txt")
        XCTAssertEqual(read(text), "")
    }

    // MARK: コピーと移動

    func testCopyFolderRecursively() async throws {
        let source = try folder("src")
        try file("src/a.txt", "A")
        try file("src/sub/b.txt", "B")
        let destination = try folder("dst")

        let result = await FileOps.transfer([source], to: destination, move: false, resolve: { _ in .skip })

        XCTAssertEqual(result.completed.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(read(destination.appendingPathComponent("src/a.txt")), "A")
        XCTAssertEqual(read(destination.appendingPathComponent("src/sub/b.txt")), "B")
        XCTAssertTrue(fm.fileExists(atPath: source.path), "コピー元は残る")
    }

    func testMoveRemovesSource() async throws {
        let source = try file("a.txt", "A")
        let destination = try folder("dst")

        let result = await FileOps.transfer([source], to: destination, move: true, resolve: { _ in .skip })

        XCTAssertEqual(result.completed.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "A")
    }

    func testConflictSkipKeepsBothFilesUntouched() async throws {
        let source = try file("a.txt", "new")
        let destination = try folder("dst")
        let existing = try file("dst/a.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: true, resolve: { _ in .skip })

        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertEqual(read(existing), "old")
        XCTAssertEqual(read(source), "new", "スキップした項目は移動されない")
    }

    func testConflictKeepBothAddsNumber() async throws {
        let source = try file("a.txt", "new")
        let destination = try folder("dst")
        let existing = try file("dst/a.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: false, resolve: { _ in .keepBoth })

        XCTAssertEqual(result.completed.first?.destination.lastPathComponent, "a (2).txt")
        XCTAssertEqual(read(existing), "old")
        XCTAssertEqual(read(destination.appendingPathComponent("a (2).txt")), "new")
    }

    func testConflictReplaceMovesOldItemToTrash() async throws {
        let source = try file("a.txt", "new")
        let destination = try folder("dst")
        let existing = try file("dst/a.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: false, resolve: { _ in .replace })
        defer { result.replaced.forEach { try? fm.removeItem(at: $0.trashed) } }

        XCTAssertEqual(read(existing), "new")
        XCTAssertEqual(result.replaced.count, 1)
        XCTAssertEqual(result.replaced.first?.original.path, existing.path)
        XCTAssertEqual(result.replaced.first.flatMap { read($0.trashed) }, "old", "置き換えられた項目はゴミ箱に残る")
    }

    func testUndoCopyWithReplaceRestoresOldItem() async throws {
        let source = try file("a.txt", "new")
        let destination = try folder("dst")
        let existing = try file("dst/a.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: false, resolve: { _ in .replace })
        try FileOps.undoTransfer(result, move: false)

        XCTAssertEqual(read(source), "new")
        XCTAssertEqual(read(existing), "old")
    }

    func testUndoMoveWithReplaceRestoresBothItems() async throws {
        let source = try file("a.txt", "new")
        let destination = try folder("dst")
        let existing = try file("dst/a.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: true, resolve: { _ in .replace })
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        try FileOps.undoTransfer(result, move: true)

        XCTAssertEqual(read(source), "new")
        XCTAssertEqual(read(existing), "old")
    }

    func testFailedReplaceRestoresExistingItem() async throws {
        let source = try folder("src")
        try file("src/a.txt", "A")
        let locked = try file("src/locked.txt", "L")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let destination = try folder("dst")
        try file("dst/src/old.txt", "old")

        let result = await FileOps.transfer([source], to: destination, move: false, resolve: { _ in .replace })

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertTrue(result.replaced.isEmpty)
        XCTAssertEqual(read(destination.appendingPathComponent("src/old.txt")), "old", "既存の項目が元に戻る")
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("src/a.txt").path), "途中までのコピーは残らない")
    }

    func testCopyIntoSameFolderMakesDuplicate() async throws {
        let source = try file("a.txt", "A")

        let result = await FileOps.transfer([source], to: root, move: false, resolve: { _ in .skip })

        let copy = try XCTUnwrap(result.completed.first?.destination)
        XCTAssertNotEqual(copy.lastPathComponent, "a.txt")
        XCTAssertEqual(read(copy), "A")
        XCTAssertEqual(read(source), "A")
    }

    func testMoveIntoSameFolderDoesNothing() async throws {
        let source = try file("a.txt", "A")
        let result = await FileOps.transfer([source], to: root, move: true, resolve: { _ in .replace })
        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertTrue(result.replaced.isEmpty)
        XCTAssertEqual(read(source), "A")
    }

    func testCopyFolderIntoItselfFails() async throws {
        let source = try folder("src")
        let inside = try folder("src/inner")

        let result = await FileOps.transfer([source], to: inside, move: false, resolve: { _ in .skip })

        XCTAssertTrue(result.completed.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testCancelledTransferStops() async throws {
        let sources = try (0..<20).map { try file("f\($0).txt") }
        let destination = try folder("dst")
        let task = Task { await FileOps.transfer(sources, to: destination, move: false, resolve: { _ in .skip }) }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.completed.isEmpty)
    }

    // MARK: ゴミ箱

    func testTrashAndRestore() throws {
        let url = try file("a.txt", "A")
        let result = FileOps.trash([url])
        defer { result.trashed.forEach { try? fm.removeItem(at: $0.trashed) } }

        XCTAssertFalse(fm.fileExists(atPath: url.path))
        let pair = try XCTUnwrap(result.trashed.first)
        XCTAssertEqual(read(pair.trashed), "A", "完全には削除しない")

        try fm.moveItem(at: pair.trashed, to: pair.original)
        XCTAssertEqual(read(url), "A")
    }

    // MARK: ZIP

    func testZipBatchRecordsEveryCreatedDirectory() async throws {
        let first = try await Zip.compress([file("one.txt", "first")])
        let second = try await Zip.compress([file("two.txt", "second")])

        let result = await Zip.extractAll([first, second])

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.created.map(\.lastPathComponent), ["one", "two"])
        let firstDirectory = try XCTUnwrap(result.created.first)
        let lastDirectory = try XCTUnwrap(result.created.last)
        XCTAssertEqual(read(firstDirectory.appendingPathComponent("one.txt")), "first")
        XCTAssertEqual(read(lastDirectory.appendingPathComponent("two.txt")), "second")
    }

    func testZipBatchKeepsCreatedDirectoriesWhenLaterArchiveFails() async throws {
        let first = try await Zip.compress([file("one.txt", "first")])
        let broken = try file("broken.zip", "invalid ZIP")
        let last = try await Zip.compress([file("last.txt")])

        let result = await Zip.extractAll([first, broken, last])

        XCTAssertEqual(result.failure?.url, broken)
        XCTAssertEqual(result.created.map(\.lastPathComponent), ["one"])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("last").path))
    }

    func testZipRoundTrip() async throws {
        _ = try folder("プロジェクト")
        try file("プロジェクト/メモ.txt", "こんにちは")
        try file("プロジェクト/sub/b.txt", "B")
        let single = try file("単体.txt", "S")

        let archive = try await Zip.compress([root.appendingPathComponent("プロジェクト"), single])
        XCTAssertEqual(archive.lastPathComponent, "アーカイブ.zip")

        let extracted = try await Zip.extract(archive)
        XCTAssertEqual(extracted.lastPathComponent, "アーカイブ")
        XCTAssertEqual(read(extracted.appendingPathComponent("プロジェクト/メモ.txt")), "こんにちは")
        XCTAssertEqual(read(extracted.appendingPathComponent("プロジェクト/sub/b.txt")), "B")
        XCTAssertEqual(read(extracted.appendingPathComponent("単体.txt")), "S")
    }

    /// /private/var のように /private から始まるパスで開いた場所でも、リンク切れのエイリアスを一緒に圧縮できる。
    /// standardizedFileURL は、リンク切れの項目だけ /private を外さないため、相対パスがずれていた
    func testZipIncludesBrokenSymlink() async throws {
        try file("a.txt", "A")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("broken").path, withDestinationPath: "nowhere")
        // resolvingSymlinksInPath も /private を外すので、realpath で実際のパスを得る
        let base = URL(fileURLWithPath: try XCTUnwrap(realpath(root.path, nil).map { String(cString: $0) }))
        XCTAssertTrue(base.path.hasPrefix("/private/"))

        let archive = try await Zip.compress([base.appendingPathComponent("a.txt"), base.appendingPathComponent("broken")])
        let extracted = try await Zip.extract(archive)
        XCTAssertEqual(read(extracted.appendingPathComponent("a.txt")), "A")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("broken").path), "nowhere")
    }

    func testZipSingleItemUsesItsName() async throws {
        let single = try file("report.txt", "R")
        let archive = try await Zip.compress([single])
        XCTAssertEqual(archive.lastPathComponent, "report.zip")
        XCTAssertTrue(fm.fileExists(atPath: single.path), "圧縮元は残る")
    }

    func testZipPreservesFilesWithSameNameInDifferentDirectories() async throws {
        let first = try file("first/same [1].txt", "first")
        let second = try file("second/same [1].txt", "second")

        let archive = try await Zip.compress([first, second])
        let extracted = try await Zip.extract(archive)

        XCTAssertEqual(read(extracted.appendingPathComponent("first/same [1].txt")), "first")
        XCTAssertEqual(read(extracted.appendingPathComponent("second/same [1].txt")), "second")
    }

    func testZipFailsWithoutPublishingPartialArchiveWhenSourceIsMissing() async throws {
        let existing = try file("here/one.txt")
        let missing = root.appendingPathComponent("gone/two.txt")

        do {
            _ = try await Zip.compress([existing, missing])
            XCTFail("選択したファイルが欠けたまま圧縮に成功した")
        } catch is FileOpsError {
            let entries = try fm.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path)
            XCTAssertEqual(entries, ["one.txt"])
        }
    }

    func testCancellingShellStopsRunningProcess() async throws {
        let ready = root.appendingPathComponent("ready")
        let task = Task {
            try await Shell.runCancellable("/bin/sh", ["-c", "touch \"$1\"; exec /bin/sleep 15", "sh", ready.path])
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(4)
        while !fm.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard fm.fileExists(atPath: ready.path) else { return XCTFail("プロセスが起動しなかった") }

        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("起動済みのプロセスを中止できなかった")
        } catch is CancellationError {
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(4))
        }
    }

    func testConflictCancellationStopsBeforeLaterItems() async throws {
        let first = try file("source/first.txt", "first")
        let conflict = try file("source/same.txt", "source")
        let last = try file("source/last.txt", "last")
        let existing = try file("target/same.txt", "target")
        let destination = existing.deletingLastPathComponent()

        let result = await FileOps.transfer([first, conflict, last], to: destination, move: true, resolve: { _ in .cancel })

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.completed.map(\.source), [first])
        XCTAssertEqual(read(conflict), "source")
        XCTAssertEqual(read(existing), "target")
        XCTAssertEqual(read(last), "last")
    }

    func testFolderSearchFindsNestedFilesWithoutSpotlight() throws {
        let visible = try file("nested/日本語 メモ.txt")
        let hidden = try file(".hidden/日本語 控え.txt")

        let visibleOnly = FileItem.searchDirectory(root, text: "日本語", showHidden: false, limit: 10)
        let includingHidden = FileItem.searchDirectory(root, text: "日本語", showHidden: true, limit: 10)

        XCTAssertEqual(visibleOnly.map(\.url), [visible.normalizedFile])
        XCTAssertEqual(Set(includingHidden.map(\.url)), Set([visible.normalizedFile, hidden.normalizedFile]))
    }

    // MARK: ドラッグ＆ドロップの判定

    func testDropWithinVolumeMoves() {
        let op = DropLogic.operation(sources: [URL(fileURLWithPath: "/a/x.txt")], target: URL(fileURLWithPath: "/b"),
                                     forceCopy: false, sameVolume: { _, _ in true })
        XCTAssertEqual(op, .move)
    }

    func testDropAcrossVolumesCopies() {
        let op = DropLogic.operation(sources: [URL(fileURLWithPath: "/a/x.txt")], target: URL(fileURLWithPath: "/Volumes/USB"),
                                     forceCopy: false, sameVolume: { _, _ in false })
        XCTAssertEqual(op, .copy)
    }

    func testDropWithOptionCopies() {
        let op = DropLogic.operation(sources: [URL(fileURLWithPath: "/a/x.txt")], target: URL(fileURLWithPath: "/b"),
                                     forceCopy: true, sameVolume: { _, _ in true })
        XCTAssertEqual(op, .copy)
    }

    func testOptionKeyOrCopyOnlySourceForcesCopy() {
        let all: NSDragOperation = [.copy, .move, .link]
        XCTAssertFalse(DropLogic.forcesCopy(sourceMask: all, optionPressed: false))
        XCTAssertTrue(DropLogic.forcesCopy(sourceMask: all, optionPressed: true))
        // Option を押している間、AppKit が渡す許可操作はコピーだけになる
        XCTAssertTrue(DropLogic.forcesCopy(sourceMask: .copy, optionPressed: false))
    }

    func testDropOntoSelfOrDescendantIsRefused() {
        let folder = URL(fileURLWithPath: "/a/folder")
        XCTAssertNil(DropLogic.operation(sources: [folder], target: folder, forceCopy: false, sameVolume: { _, _ in true }))
        XCTAssertNil(DropLogic.operation(sources: [folder], target: URL(fileURLWithPath: "/a/folder/sub"),
                                         forceCopy: true, sameVolume: { _, _ in true }))
    }

    func testDropIntoCurrentParentIsRefusedForMoveButAllowedForCopy() {
        let source = URL(fileURLWithPath: "/a/x.txt")
        let parent = URL(fileURLWithPath: "/a")
        XCTAssertNil(DropLogic.operation(sources: [source], target: parent, forceCopy: false, sameVolume: { _, _ in true }))
        XCTAssertEqual(DropLogic.operation(sources: [source], target: parent, forceCopy: true, sameVolume: { _, _ in true }), .copy)
    }

    // MARK: 並べ替え

    func testFoldersAlwaysComeFirst() throws {
        try file("b.txt")
        try file("a10.txt")
        try file("a2.txt")
        _ = try folder("zzz")
        let items = try FileItem.loadDirectory(root, showHidden: false)

        let ascending = FileItem.sorted(items, key: .name, ascending: true).map(\.name)
        XCTAssertEqual(ascending, ["zzz", "a2.txt", "a10.txt", "b.txt"])

        let descending = FileItem.sorted(items, key: .name, ascending: false).map(\.name)
        XCTAssertEqual(descending, ["zzz", "b.txt", "a10.txt", "a2.txt"])
    }

    func testFolderItemURLMatchesURLBuiltFromPath() throws {
        let created = try FileOps.createFolder(in: root, name: "新しいフォルダー")
        let items = try FileItem.loadDirectory(root, showHidden: false)
        XCTAssertEqual(items.map(\.url), [created.normalizedFile], "作成直後のフォルダを選択できるよう、URL の形をそろえる")
        XCTAssertEqual(items.first?.url, root.appendingPathComponent("新しいフォルダー").normalizedFile)
    }

    func testHiddenFilesAreSkippedUnlessRequested() throws {
        try file(".hidden")
        try file("shown.txt")
        XCTAssertEqual(try FileItem.loadDirectory(root, showHidden: false).map(\.name), ["shown.txt"])
        XCTAssertEqual(try FileItem.loadDirectory(root, showHidden: true).count, 2)
    }

    func testSymlinkToFolderIsListedAsFolder() throws {
        let target = try folder("target")
        let fileTarget = try file("file.txt")
        try fm.createSymbolicLink(at: root.appendingPathComponent("folderLink"), withDestinationURL: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("fileLink"), withDestinationURL: fileTarget)
        let items = try FileItem.loadDirectory(root, showHidden: false)
        XCTAssertEqual(items.first { $0.name == "folderLink" }?.isDirectory, true, "/tmp のようなリンクも中に入れるフォルダとして扱う")
        XCTAssertEqual(items.first { $0.name == "fileLink" }?.isDirectory, false)
    }

    // MARK: 一覧の読み込み

    func testLoadDirectoryReadsTagsButNotThroughSymlinks() throws {
        let tagged = try file("tagged.txt")
        Tags.toggle(1, on: [tagged])
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: tagged)

        let items = try FileItem.loadDirectory(root, showHidden: false)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["tagged.txt"]?.tags, [1])
        // リンク先のタグはたどらない（自動マウントの場所で読み込みが止まるのを避ける）
        XCTAssertEqual(byName["link.txt"]?.tags, [])
    }
    // MARK: 切り取りの再試行

    @MainActor
    func testCutPasteRetainsUnmovedItemsAndConsumesSuccessfulMoves() async throws {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board)
        let first = try file("first.txt")
        let second = try file("second.txt")
        clipboard.write([first, second], cut: true)

        let firstPaste = try XCTUnwrap(clipboard.beginCutPaste())
        XCTAssertNil(clipboard.beginCutPaste())
        clipboard.finishCutPaste(firstPaste, moved: [first])

        XCTAssertEqual(clipboard.urls, [second])
        XCTAssertTrue(clipboard.isCutItem(second))
        let retry = try XCTUnwrap(clipboard.beginCutPaste())
        clipboard.finishCutPaste(retry, moved: [second])
        XCTAssertTrue(clipboard.urls.isEmpty)
        XCTAssertFalse(clipboard.isCut)
    }

    @MainActor
    func testCutPasteCompletionPreservesNewClipboardContents() async throws {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board)
        let file = try file("clip.txt")
        clipboard.write([file], cut: true)
        let paste = try XCTUnwrap(clipboard.beginCutPaste())

        board.clearContents()
        board.setString("new clipboard content", forType: .string)
        clipboard.finishCutPaste(paste, moved: [file])

        XCTAssertEqual(board.string(forType: .string), "new clipboard content")
        XCTAssertFalse(clipboard.isCut)
    }
}
