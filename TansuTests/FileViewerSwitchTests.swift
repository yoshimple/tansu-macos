import XCTest
@testable import Tansu

/// 「他のアプリからTansuを開く」の切り替え。実際の macOS の設定には触れず、仮の保存先で確かめる
final class FileViewerSwitchTests: XCTestCase {
    private final class Box {
        var value: String?
        var writable = true
    }

    private var box: Box!
    private var store: UserDefaults!
    private let suite = "TansuFileViewerSwitchTests"

    override func setUp() {
        box = Box()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    private func makeSwitch() -> FileViewerSwitch {
        let box = box!
        return FileViewerSwitch(
            read: { box.value },
            write: { if box.writable { box.value = $0 } },
            ownID: "dev.tansu.Tansu", store: store)
    }

    func testEnableThenDisableRestoresUnsetState() {
        let fileViewer = makeSwitch()
        XCTAssertFalse(fileViewer.isEnabled)

        XCTAssertTrue(fileViewer.enable())
        XCTAssertEqual(box.value, "dev.tansu.Tansu")
        XCTAssertTrue(fileViewer.isEnabled)

        XCTAssertTrue(fileViewer.disable())
        XCTAssertNil(box.value, "元が未指定なら、未指定に戻す")
    }

    func testDisableRestoresPreviousViewer() {
        box.value = "com.example.OtherViewer"
        let fileViewer = makeSwitch()

        XCTAssertTrue(fileViewer.enable())
        XCTAssertTrue(fileViewer.disable())
        XCTAssertEqual(box.value, "com.example.OtherViewer", "有効にする直前の表示先に戻す")
    }

    func testDisableRespectsViewerChangedElsewhere() {
        let fileViewer = makeSwitch()
        XCTAssertTrue(fileViewer.enable())
        box.value = "com.example.OtherViewer"   // 有効にした後、別のアプリが指定された

        XCTAssertFalse(fileViewer.isEnabled, "スイッチは実際の表示先を反映する")
        XCTAssertTrue(fileViewer.disable())
        XCTAssertEqual(box.value, "com.example.OtherViewer", "別のアプリの指定には触れない")
    }

    func testEnableTwiceKeepsOriginalPreviousViewer() {
        box.value = "com.example.OtherViewer"
        let fileViewer = makeSwitch()
        XCTAssertTrue(fileViewer.enable())
        XCTAssertTrue(fileViewer.enable())
        XCTAssertTrue(fileViewer.disable())
        XCTAssertEqual(box.value, "com.example.OtherViewer")
    }

    func testFailureIsReportedAndStateIsUnchanged() {
        box.writable = false
        let fileViewer = makeSwitch()
        XCTAssertFalse(fileViewer.enable(), "書き込めなければ失敗を返す")
        XCTAssertFalse(fileViewer.isEnabled)

        box.writable = true
        XCTAssertTrue(fileViewer.enable())
        box.writable = false
        XCTAssertFalse(fileViewer.disable(), "戻せなければ失敗を返す")
        XCTAssertTrue(fileViewer.isEnabled, "実際の状態（有効のまま）を返す")
    }
}

/// 表示要求を受けたときのタブの開き方
@MainActor
final class RevealTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TansuRevealTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "sub/c.txt"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForSelection(_ tab: TabModel) async throws {
        for _ in 0..<100 where tab.selection.isEmpty {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testRevealOpensParentInNewTabAndSelectsItem() async throws {
        let model = WindowModel(state: WindowState(frame: nil, tabs: [root.appendingPathComponent("sub").path], selected: 0, showPreview: false))
        let target = root.appendingPathComponent("b.txt")

        model.reveal([target])

        XCTAssertEqual(model.tabs.count, 2, "開いていないフォルダは新しいタブで開く")
        XCTAssertEqual(model.tab.url.normalizedFile, root.normalizedFile)
        try await waitForSelection(model.tab)
        XCTAssertEqual(model.tab.selection, [target.normalizedFile])
    }

    func testRevealReusesTabAlreadyShowingTheFolder() async throws {
        let model = WindowModel(state: WindowState(frame: nil, tabs: [root.path], selected: 0, showPreview: false))
        let folder = root.appendingPathComponent("sub")

        model.reveal([folder])

        XCTAssertEqual(model.tabs.count, 1, "すでに開いているフォルダは、そのタブを使う")
        try await waitForSelection(model.tab)
        XCTAssertEqual(model.tab.selection, [folder.normalizedFile], "フォルダが渡されたときも、親フォルダの中で選択する")
    }

    func testRevealSelectsSeveralItemsInTheSameFolder() async throws {
        let model = WindowModel(state: WindowState(frame: nil, tabs: [root.appendingPathComponent("sub").path], selected: 0, showPreview: false))
        let targets = [root.appendingPathComponent("a.txt"), root.appendingPathComponent("b.txt")]

        model.reveal(targets)

        XCTAssertEqual(model.tabs.count, 2)
        try await waitForSelection(model.tab)
        XCTAssertEqual(model.tab.selection, Set(targets.map(\.normalizedFile)))
    }
}

/// 検索結果からの「戻る」
@MainActor
final class SearchBackTests: XCTestCase {
    func testGoBackWhileSearchingClearsSearchAndStaysInFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TansuSearchBackTests-" + UUID().uuidString)
        let alpha = root.appendingPathComponent("Alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = TabModel(url: root)
        tab.navigate(to: alpha)

        tab.searchText = "alpha"
        XCTAssertTrue(tab.canGoBack)
        tab.goBack()

        XCTAssertEqual(tab.searchText, "")
        XCTAssertEqual(tab.url.normalizedFile, alpha.normalizedFile, "検索を解除するだけで、親フォルダへは移らない")

        tab.goBack()
        XCTAssertEqual(tab.url.normalizedFile, root.normalizedFile, "検索していなければ通常どおり戻る")
    }
}
