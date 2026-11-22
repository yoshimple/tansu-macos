import XCTest
@testable import Tansu

/// 一覧の上でのドロップ先の判定が、実際に表示されている項目の位置と一致することを確かめる
@MainActor
final class DropTargetTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TansuDropTests-" + UUID().uuidString)
        for name in ["docs", "reports", "src"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["beta.txt", "gamma.txt", "readme.md"] {
            try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDropTargetMatchesItemUnderPointer() async throws {
        let model = WindowModel(state: WindowState(frame: nil, tabs: [root.path], selected: 0, showPreview: false))
        let controller = FileListViewController(model: model, tab: model.tab)
        // アプリ本体と同じ UserDefaults を使うので、列幅とフォルダごとの表示形式を書き残さない
        controller.loadViewIfNeeded()
        controller.tableView.autosaveTableColumns = false
        addTeardownBlock { @MainActor in model.tab.setViewMode(.details) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 420))

        for _ in 0..<100 where model.tab.items.isEmpty {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(model.tab.items.count, 6)

        for mode in [ViewMode.details, .list, .icons] {
            model.tab.setViewMode(mode)
            controller.update()
            window.contentView?.layoutSubtreeIfNeeded()
            controller.collectionView.layoutSubtreeIfNeeded()

            for (index, item) in controller.items.enumerated() {
                let center: NSPoint
                if mode == .details {
                    let rect = controller.tableView.rect(ofRow: index)
                    center = controller.tableView.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
                } else {
                    let frame = try XCTUnwrap(controller.collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
                    center = controller.collectionView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                }
                let expected = item.isDirectory ? index : nil
                XCTAssertEqual(controller.folderIndex(atWindowPoint: center), expected, "\(mode) \(item.name)")
            }
        }
        window.close()
    }
}
