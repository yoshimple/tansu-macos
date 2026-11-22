import SwiftUI
import AppKit

enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// タブバーの背景
    static let strip = dynamic(NSColor(white: 0.90, alpha: 1), NSColor(white: 0.12, alpha: 1))
    /// 選択中のタブ、ナビゲーション行、コマンドバーの背景
    static let toolbar = dynamic(NSColor(white: 0.97, alpha: 1), NSColor(white: 0.17, alpha: 1))
    /// ファイル一覧の背景
    static let content = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let hover = Color.primary.opacity(0.08)
    /// AppKit のファイル一覧で使う、マウスが乗った行の背景（hover と同じ色）
    static let hoverFill = NSColor.labelColor.withAlphaComponent(0.08)
    static let selected = Color.accentColor.opacity(0.20)
    static let folder = Color(red: 0.36, green: 0.62, blue: 0.93)

    static let tabBarHeight: CGFloat = 40
}

/// コマンドバーなどで使うアイコンだけのボタン
struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .toolTip(help)
        .accessibilityLabel(help)
    }
}
