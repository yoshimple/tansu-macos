import SwiftUI
import Quartz

/// 右側のプレビューウィンドウ。選択中のファイルを1つだけ表示する
struct PreviewPane: View {
    @ObservedObject var tab: TabModel

    var body: some View {
        Group {
            if tab.selection.count == 1, let url = tab.selection.first {
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                    MarkdownPreview(url: url)
                } else {
                    QuickLookPreview(url: url)
                }
            } else {
                Text(tab.selection.isEmpty ? L("プレビューするファイルを選択してください。") : L("%d個の項目を選択", tab.selection.count))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.content)
    }
}

/// Quick Look による埋め込みプレビュー
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }
}
