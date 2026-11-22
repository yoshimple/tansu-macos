import XCTest
@testable import Tansu

@MainActor
final class TabNavigationTests: XCTestCase {
    func testOpeningDirectoryLinkNavigatesToItsTarget() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let drive = root.appendingPathComponent("GoogleDrive-test")
        let link = drive.appendingPathComponent("マイドライブ")
        let mirror = root.appendingPathComponent("マイドライブ")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: mirror)

        let tab = TabModel(url: drive)
        XCTAssertTrue(tab.navigate(to: link))
        XCTAssertEqual(tab.url.normalizedFile, mirror.normalizedFile)
        XCTAssertEqual(TabModel(url: link).url.normalizedFile, mirror.normalizedFile)

        XCTAssertTrue(tab.navigate(to: link))
        tab.goBack()
        XCTAssertEqual(tab.url.normalizedFile, drive.normalizedFile)
    }
}
