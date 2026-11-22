import XCTest
@testable import Tansu

final class AIExportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("TansuAITests-" + UUID().uuidString)
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

    // MARK: パス

    func testPathStyles() {
        let base = URL(fileURLWithPath: "/repo")
        let urls = [URL(fileURLWithPath: "/repo/src/a.swift"), URL(fileURLWithPath: "/repo/README.md")]
        XCTAssertEqual(AIExport.paths(urls, style: .absolute, base: base), "/repo/src/a.swift\n/repo/README.md")
        XCTAssertEqual(AIExport.paths(urls, style: .relative, base: base), "src/a.swift\nREADME.md")
        XCTAssertEqual(AIExport.paths(urls, style: .atRelative, base: base), "@src/a.swift\n@README.md")
    }

    func testRelativePathOutsideBaseStaysAbsolute() {
        let base = URL(fileURLWithPath: "/repo")
        XCTAssertEqual(AIExport.relativePath(URL(fileURLWithPath: "/other/x.txt"), to: base), "/other/x.txt")
        XCTAssertEqual(AIExport.relativePath(URL(fileURLWithPath: "/repository/x.txt"), to: base), "/repository/x.txt")
        XCTAssertEqual(AIExport.relativePath(base, to: base), ".")
    }

    // MARK: 機密ファイル

    func testSensitiveFiles() {
        let sensitive = [".env", ".env.local", ".env.production", "id_rsa", "id_ed25519", "server.pem", "private.key",
                         "cert.p12", "credentials.json", "aws_secret.txt", ".npmrc", "/Users/x/.ssh/config"]
        for name in sensitive {
            XCTAssertTrue(AIExport.isSensitive(URL(fileURLWithPath: name.hasPrefix("/") ? name : "/repo/" + name)), name)
        }
        let safe = [".env.example", ".env.sample", "main.swift", "README.md", "keyboard.swift", "id_rsa.pub.txt", "environment.ts"]
        for name in safe {
            XCTAssertFalse(AIExport.isSensitive(URL(fileURLWithPath: "/repo/" + name)), name)
        }
    }

    // MARK: AI用にコピー

    func testMarkdownBundleSkipsBinary() throws {
        let text = try file("src/main.swift", "print(1)\n")
        let japanese = try file("メモ.md", "こんにちは")
        let binary = root.appendingPathComponent("image.bin")
        try Data([0x00, 0xFF, 0x10, 0x00]).write(to: binary)

        let bundle = AIExport.markdown(for: [text, japanese, binary], base: root)

        XCTAssertEqual(bundle.included, 2)
        XCTAssertEqual(bundle.binary, [binary])
        XCTAssertTrue(bundle.text.contains("## src/main.swift\n\n```swift\nprint(1)\n```\n"))
        XCTAssertTrue(bundle.text.contains("## メモ.md\n\n```md\nこんにちは\n```\n"))
        XCTAssertFalse(bundle.text.contains("image.bin"))
    }

    func testFenceGrowsWhenContentContainsBackticks() {
        let section = AIExport.section(path: "a.md", language: "md", content: "```swift\nlet a = 1\n```\n")
        XCTAssertTrue(section.hasPrefix("## a.md\n\n````md\n"))
        XCTAssertTrue(section.hasSuffix("\n````\n"))
    }

    func testCollectFilesExpandsFoldersAndSkipsExcluded() throws {
        try file("proj/a.txt")
        try file("proj/sub/b.txt")
        try file("proj/node_modules/pkg/index.js")
        try file("proj/.git/config")
        let single = try file("single.txt")

        let names = AIExport.collectFiles([root.appendingPathComponent("proj"), single]).map { AIExport.relativePath($0, to: root) }

        XCTAssertEqual(names, ["proj/a.txt", "proj/sub/b.txt", "single.txt"])
    }

    func testGitIgnoreIsRespectedInsideRepository() throws {
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/git", ["-C", repo.path, "init", "-q"]).succeeded else {
            throw XCTSkip("git を使えない環境")
        }
        try file("repo/.gitignore", "build/\n*.log\n")
        try file("repo/src/main.swift")
        try file("repo/build/out.o")
        try file("repo/debug.log")

        XCTAssertEqual(AIExport.listFiles(in: repo), [".gitignore", "src/main.swift"])

        let tree = AIExport.tree(of: repo)
        XCTAssertEqual(tree, "repo/\n├── src/\n│   └── main.swift\n└── .gitignore\n")
    }

    // MARK: フォルダ構成

    func testRenderTree() {
        let tree = AIExport.renderTree(rootName: "my-app", paths: [
            "README.md", "src/main.swift", "src/views/ContentView.swift", "tests/a.swift",
        ])
        XCTAssertEqual(tree, """
        my-app/
        ├── src/
        │   ├── views/
        │   │   └── ContentView.swift
        │   └── main.swift
        ├── tests/
        │   └── a.swift
        └── README.md

        """)
    }

    // MARK: トークン数

    func testTokenEstimate() {
        XCTAssertEqual(AIExport.estimateTokens(""), 0)
        XCTAssertEqual(AIExport.estimateTokens("abcdefgh"), 2)
        XCTAssertEqual(AIExport.estimateTokens("こんにちは"), 5)
        XCTAssertEqual(AIExport.formatTokens(950), "950")
        XCTAssertEqual(AIExport.formatTokens(1234), "1.2k")
    }

    // MARK: Git の状態

    func testParseGitStatus() {
        let root = URL(fileURLWithPath: "/repo")
        let output = ["## main...origin/main", " M src/a.swift", "A  src/new.swift", "?? notes/", "R  renamed.txt", "old.txt", "!! ignored.log"]
            .joined(separator: "\0") + "\0"

        let parsed = Git.parseStatus(output, root: root)

        XCTAssertEqual(parsed.branch, "main")
        XCTAssertEqual(parsed.status["/repo/src/a.swift"], "M")
        XCTAssertEqual(parsed.status["/repo/src/new.swift"], "A")
        XCTAssertEqual(parsed.status["/repo/notes"], "?")
        XCTAssertEqual(parsed.status["/repo/renamed.txt"], "M")
        XCTAssertNil(parsed.status["/repo/old.txt"], "名前変更の元のパスは項目として数えない")
        XCTAssertNil(parsed.status["/repo/ignored.log"])
        XCTAssertEqual(parsed.status["/repo/src"], "M", "変更を含むフォルダにも印が付く")
    }

    func testParseGitBranchVariants() {
        let root = URL(fileURLWithPath: "/repo")
        XCTAssertEqual(Git.parseStatus("## No commits yet on main\0", root: root).branch, "main")
        XCTAssertEqual(Git.parseStatus("## feature/x\0", root: root).branch, "feature/x")
        XCTAssertEqual(Git.parseStatus("## HEAD (no branch)\0", root: root).branch, "HEAD")
    }

    // MARK: Markdown

    func testMarkdownParse() {
        let text = """
        # 見出し

        本文の1行目
        2行目

        - 項目A
          - 子項目
        - [x] 完了
        1. 番号

        > 引用

        ```swift
        let a = 1
        ```

        ---

        | 列1 | 列2 |
        |---|---|
        | a | b |
        """
        XCTAssertEqual(Markdown.parse(text), [
            .heading(level: 1, text: "見出し"),
            .paragraph("本文の1行目\n2行目"),
            .bullet(text: "項目A", level: 0, marker: "•"),
            .bullet(text: "子項目", level: 1, marker: "•"),
            .bullet(text: "完了", level: 0, marker: "☑"),
            .bullet(text: "番号", level: 0, marker: "1."),
            .quote("引用"),
            .code("let a = 1"),
            .rule,
            .table([["列1", "列2"], ["a", "b"]]),
        ])
    }

    // MARK: 設定ファイル

    func testSettingsDecodeFillsMissingKeys() throws {
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"aiFeaturesEnabled": false}"#.utf8))
        XCTAssertFalse(partial.aiFeaturesEnabled)
        XCTAssertEqual(partial.agents.map(\.name), ["Claude Code", "Codex"])

        let custom = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"agents":[{"name":"Gemini","command":"gemini"}]}"#.utf8))
        XCTAssertTrue(custom.aiFeaturesEnabled)
        XCTAssertEqual(custom.agents, [AgentSetting(name: "Gemini", command: "gemini")])
    }
}
