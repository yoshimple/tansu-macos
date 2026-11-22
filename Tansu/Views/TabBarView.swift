import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// ウィンドウ最上部（タイトルバーの位置）のタブバー。右端に「＋」ボタンを置く
struct TabBarView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // 閉じる・最小化・最大化ボタンの分を空ける
            Color.clear.frame(width: 80)
            GeometryReader { geometry in
                let tabWidth = max(110, geometry.size.width / CGFloat(model.tabs.count))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(model.tabs) { tab in
                                TabItemView(model: model, tab: tab, selected: tab.id == model.selectedTabID)
                                    .frame(width: tabWidth)
                                    .id(tab.id)
                            }
                        }
                        .frame(height: geometry.size.height, alignment: .bottom)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selectedTabID, initial: true) { _, id in
                        proxy.scrollTo(id)
                    }
                    .onChange(of: geometry.size.width) {
                        proxy.scrollTo(model.selectedTabID)
                    }
                }
            }
            .frame(maxWidth: CGFloat(model.tabs.count) * 220)
            IconButton(symbol: "plus", help: L("新しいタブ"), size: 12) { model.newTab() }
                .padding(.leading, 4)
                .padding(.bottom, 2)
            Spacer(minLength: 60)
        }
        .frame(height: Theme.tabBarHeight)
        .background(WindowDragArea())
        .background(Theme.strip)
    }
}

private struct TabItemView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    let selected: Bool
    @State private var hover = false
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                model.selectTab(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: !tab.searchText.isEmpty ? "magnifyingglass" : tab.isRecents ? "clock.fill" : "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.folder)
                    Text(tab.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, 28)
                .frame(height: 32)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                        .fill(selected ? Theme.toolbar : (hover || dropTargeted ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected || hover {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .toolTip(L("タブを閉じる"))
            }
        }
        // エクスプローラーと同じく、タブにはフォルダの場所を出す
        .toolTip(tab.url.isFileURL && !tab.isSearching ? tab.url.path : tab.title)
        .onHover { hover = $0 }
        // ファイルをドラッグしたままタブの上に来たら、そのタブへ切り替える
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { _ in false }
        .onChange(of: dropTargeted) { _, targeted in
            if targeted { model.selectTab(tab.id) }
        }
        .contextMenu {
            Button(L("タブを閉じる")) { model.closeTab(tab.id) }
            Button(L("ほかのタブを閉じる")) { model.closeOtherTabs(tab.id) }
                .disabled(model.tabs.count < 2)
            Button(L("右側のタブを閉じる")) { model.closeTabsToRight(of: tab.id) }
                .disabled(model.tabs.last?.id == tab.id)
            Button(L("タブを複製")) { model.newTab(url: tab.url) }
        }
    }
}

/// 何もない部分をドラッグするとウィンドウを動かし、ダブルクリックで拡大／縮小する
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}
