import Foundation

/// 表示文字列の取得。キーは日本語の文言そのもので、英語訳は Localizable.xcstrings に置く。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
