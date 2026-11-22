import Foundation

/// Git リポジトリ内のフォルダを開いたときに表示する情報
struct GitInfo: Equatable {
    let root: URL
    let branch: String
    /// 絶対パス → 状態（"M"、"A"、"?"）。変更を含むフォルダにも付ける
    let status: [String: String]

    func status(for url: URL) -> String? {
        status[url.resolvingSymlinksInPath().path]
    }
}

enum Git {
    private static let executable = "/usr/bin/git"

    /// リポジトリの最上位フォルダ。リポジトリ外なら nil
    static func root(for directory: URL) -> URL? {
        let output = Shell.run(executable, ["-C", directory.path, "rev-parse", "--show-toplevel"])
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.succeeded, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// ブランチ名と変更状態。リポジトリ外なら nil。時間がかかることがあるのでバックグラウンドで呼ぶ
    static func info(for directory: URL) -> GitInfo? {
        guard let root = root(for: directory) else { return nil }
        let output = Shell.run(executable, ["-C", root.path, "status", "--porcelain=v1", "-z", "--branch"])
        guard output.succeeded else { return nil }
        let parsed = parseStatus(output.text, root: root)
        return GitInfo(root: root, branch: parsed.branch, status: parsed.status)
    }

    /// `git status --porcelain=v1 -z --branch` の出力を読み取る
    static func parseStatus(_ output: String, root: URL) -> (branch: String, status: [String: String]) {
        var branch = ""
        var status: [String: String] = [:]
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            if entry.hasPrefix("## ") {
                branch = parseBranch(String(entry.dropFirst(3)))
                continue
            }
            guard entry.count > 3 else { continue }
            let code = String(entry.prefix(2))
            var path = String(entry.dropFirst(3))
            // 名前変更とコピーは、続けて元のパスが来る
            if code.contains("R") || code.contains("C") {
                index += 1
            }
            if code == "!!" { continue }
            let mark = code == "??" ? "?" : (code.contains("A") ? "A" : "M")
            if path.hasSuffix("/") { path.removeLast() }

            var url = root.appendingPathComponent(path)
            status[url.path] = mark
            // 変更を含むフォルダにも印を付ける
            url.deleteLastPathComponent()
            while url.path.count > root.path.count {
                if let existing = status[url.path] {
                    if existing != mark { status[url.path] = "M" }
                } else {
                    status[url.path] = mark
                }
                url.deleteLastPathComponent()
            }
        }
        return (branch, status)
    }

    private static func parseBranch(_ header: String) -> String {
        if header.hasPrefix("No commits yet on ") {
            return String(header.dropFirst("No commits yet on ".count))
        }
        if header.hasPrefix("HEAD (no branch)") {
            return "HEAD"
        }
        if let range = header.range(of: "...") {
            return String(header[..<range.lowerBound])
        }
        return header
    }

    /// 無視されていないファイルの一覧（directory からの相対パス）。リポジトリ外なら nil
    static func listFiles(in directory: URL) -> [String]? {
        let output = Shell.run(executable, ["-C", directory.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        guard output.succeeded else { return nil }
        return output.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}
