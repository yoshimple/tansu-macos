import Foundation

/// 外部の AI ツールへファイルを渡すための文字列を作る。アプリ自身は AI を呼ばず、通信もしない
enum AIExport {
    enum PathStyle {
        case absolute, relative, atRelative
    }

    /// 1ファイルあたりの上限。これより大きいファイルは「AI用にコピー」から除く
    static let maxFileSize = 1_000_000
    /// 一度に扱うファイル数の上限
    static let maxFiles = 2000

    private static let excludedNames: Set<String> = [".git", "node_modules", ".DS_Store"]

    // MARK: パス

    /// base からの相対パス。base の外にある場合は絶対パスを返す
    static func relativePath(_ url: URL, to base: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let basePath = base.resolvingSymlinksInPath().path
        if path == basePath { return "." }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// 複数の項目は改行で区切る
    static func paths(_ urls: [URL], style: PathStyle, base: URL) -> String {
        urls.map { url in
            switch style {
            case .absolute: return url.path
            case .relative: return relativePath(url, to: base)
            case .atRelative: return "@" + relativePath(url, to: base)
            }
        }.joined(separator: "\n")
    }

    // MARK: 機密ファイル

    /// .env、秘密鍵、認証情報らしいファイルか
    static func isSensitive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if name == ".env" { return true }
        if name.hasPrefix(".env.") {
            return ![".example", ".sample", ".template", ".dist"].contains { name.hasSuffix($0) }
        }
        let exactNames: Set<String> = [
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".netrc", ".npmrc", ".pypirc", ".htpasswd",
            "credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml", "service-account.json",
        ]
        if exactNames.contains(name) { return true }
        if ["pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "kdbx"].contains(ext) { return true }
        if ["secret", "credential", "private_key", "privatekey"].contains(where: name.contains) { return true }
        let path = url.path.lowercased()
        return ["/.ssh/", "/.aws/", "/.gnupg/"].contains(where: path.contains)
    }

    // MARK: 対象ファイルの収集

    /// 選択された項目をファイルの一覧に展開する。フォルダは中のファイルに置き換える
    static func collectFiles(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                result += listFiles(in: url).map { url.appendingPathComponent($0) }
            } else {
                result.append(url)
            }
            if result.count > maxFiles { break }
        }
        return Array(result.prefix(maxFiles))
    }

    /// フォルダ以下のファイル（相対パス）。.gitignore の対象、.git、node_modules は除く
    static func listFiles(in directory: URL) -> [String] {
        let listed: [String]
        if let tracked = Git.listFiles(in: directory) {
            listed = tracked.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        } else {
            listed = walk(directory)
        }
        return listed
            .filter { path in !path.split(separator: "/").contains { excludedNames.contains(String($0)) } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Git リポジトリ外のフォルダを自前でたどる
    private static func walk(_ directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        let base = directory.resolvingSymlinksInPath().path
        var result: [String] = []
        for case let url as URL in enumerator {
            if excludedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                let path = url.resolvingSymlinksInPath().path
                result.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent)
            }
            if result.count > maxFiles * 5 { break }
        }
        return result
    }

    // MARK: AI用にコピー

    struct Bundle {
        var text = ""
        var included = 0
        var binary: [URL] = []
        var tooLarge: [URL] = []
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0) || String(data: data, encoding: .utf8) == nil
    }

    /// ファイルごとに「相対パスの見出し＋Markdown コードブロック」を並べる。バイナリと大きすぎるファイルは除く
    static func markdown(for files: [URL], base: URL) -> Bundle {
        var bundle = Bundle()
        var sections: [String] = []
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > maxFileSize {
                bundle.tooLarge.append(file)
                continue
            }
            guard let data = try? Data(contentsOf: file), !isBinary(data),
                  let content = String(data: data, encoding: .utf8) else {
                bundle.binary.append(file)
                continue
            }
            sections.append(section(path: relativePath(file, to: base), language: file.pathExtension.lowercased(), content: content))
            bundle.included += 1
        }
        bundle.text = sections.joined(separator: "\n")
        return bundle
    }

    static func section(path: String, language: String, content: String) -> String {
        // 中身に ``` が含まれていても壊れないよう、それより長い区切りを使う
        var longest = 0, run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = content.hasSuffix("\n") ? content : content + "\n"
        return "## \(path)\n\n\(fence)\(language)\n\(body)\(fence)\n"
    }

    // MARK: フォルダ構成

    /// フォルダ以下の構成を、tree コマンドのような文字の図にする
    static func tree(of directory: URL) -> String {
        renderTree(rootName: directory.lastPathComponent, paths: listFiles(in: directory))
    }

    private final class Node {
        var children: [String: Node] = [:]
        var isDirectory = false
    }

    static func renderTree(rootName: String, paths: [String], maxLines: Int = 5000) -> String {
        let root = Node()
        for path in paths {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let child = node.children[part] ?? Node()
                if index < parts.count - 1 { child.isDirectory = true }
                node.children[part] = child
                node = child
            }
        }
        var lines = [rootName + "/"]
        func append(_ node: Node, prefix: String) {
            // フォルダを先に、名前順で並べる
            let names = node.children.keys.sorted { a, b in
                let x = node.children[a]!.isDirectory, y = node.children[b]!.isDirectory
                return x != y ? x : a.localizedStandardCompare(b) == .orderedAscending
            }
            for (index, name) in names.enumerated() {
                guard lines.count < maxLines else { return }
                let child = node.children[name]!
                let last = index == names.count - 1
                lines.append(prefix + (last ? "└── " : "├── ") + name + (child.isDirectory ? "/" : ""))
                append(child, prefix: prefix + (last ? "    " : "│   "))
            }
        }
        append(root, prefix: "")
        if lines.count >= maxLines {
            lines.append("…")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: トークン数の目安

    /// 文字数からの概算。英数字は4文字で1トークン、それ以外（日本語など）は1文字で1トークンとみなす
    static func estimateTokens(_ text: String) -> Int {
        var ascii = 0, other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + 3) / 4 + other
    }

    /// 選択中のファイルの推定トークン数。テキストでないファイルと大きすぎるファイルは数えない
    static func estimateTokens(of files: [URL]) -> Int {
        var total = 0
        for file in files.prefix(200) {
            if Task.isCancelled { break }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= maxFileSize, let data = try? Data(contentsOf: file), !isBinary(data),
                  let text = String(data: data, encoding: .utf8) else { continue }
            total += estimateTokens(text)
        }
        return total
    }

    static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
