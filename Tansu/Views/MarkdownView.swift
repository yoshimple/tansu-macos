import SwiftUI

/// Markdown を構成する部品
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String)
    case bullet(text: String, level: Int, marker: String)
    case quote(String)
    case rule
    case table([[String]])
}

/// 外部ライブラリを使わない、プレビュー用の簡易 Markdown 解析
enum Markdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            // コードブロック
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            // 見出し
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                flush()
                blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // 区切り線
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, ["-", "*", "_"].contains(where: { compact == String(repeating: $0, count: compact.count) }) {
                flush()
                blocks.append(.rule)
                continue
            }
            // 引用
            if trimmed.hasPrefix(">") {
                flush()
                var quoted = [trimmed.dropFirst().trimmingCharacters(in: .whitespaces)]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(lines[index].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            // 表（次の行が |---|---| の形）
            if trimmed.hasPrefix("|"), index < lines.count, isTableSeparator(lines[index]) {
                flush()
                var rows = [cells(trimmed)]
                index += 1
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }
            // 箇条書き
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let body = line.trimmingCharacters(in: .whitespaces)
        let level = indent / 2
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            var text = String(body.dropFirst(2))
            var symbol = "•"
            if text.hasPrefix("[ ] ") {
                symbol = "☐"
                text = String(text.dropFirst(4))
            } else if text.lowercased().hasPrefix("[x] ") {
                symbol = "☑"
                text = String(text.dropFirst(4))
            }
            return .bullet(text: text, level: level, marker: symbol)
        }
        // 番号付き（「1. 」「2) 」）
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4 {
            let rest = body.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .bullet(text: String(rest.dropFirst(2)), level: level, marker: String(digits) + ".")
            }
        }
        return nil
    }
}

/// プレビューウィンドウで Markdown ファイルを整形して表示する
struct MarkdownPreview: View {
    let url: URL
    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: url) {
            let url = url
            blocks = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url), data.count <= AIExport.maxFileSize * 2,
                      let text = String(data: data, encoding: .utf8) else { return [] }
                return Markdown.parse(text)
            }.value
        }
    }

    /// 太字、斜体、コード、リンクなどの行内の書式を反映する
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [24, 20, 17, 15, 14, 13]
            VStack(alignment: .leading, spacing: 4) {
                Text(inline(text))
                    .font(.system(size: sizes[min(level, 6) - 1], weight: .bold))
                    .padding(.top, level <= 2 ? 6 : 2)
                if level <= 2 { Divider() }
            }
        case .paragraph(let text):
            Text(inline(text)).font(.system(size: 13)).lineSpacing(3)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
        case .bullet(let text, let level, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).lineSpacing(3)
            }
            .font(.system(size: 13))
            .padding(.leading, CGFloat(level) * 18 + 4)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.border).frame(width: 3)
                Text(inline(text)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                        }
                    }
                    if rowIndex == 0 { Divider() }
                }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
        }
    }
}
