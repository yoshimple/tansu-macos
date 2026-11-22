import SwiftUI

/// ウィンドウ全体。上から、タブバー、ナビゲーション行、コマンドバー、本体、ステータスバー
struct BrowserView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var progress = ProgressCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(model: model)
            TabContentView(model: model, tab: model.tab)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.toast)
        .overlay {
            if progress.visible {
                ProgressDialog(progress: progress)
            }
        }
    }
}

/// 選択中のタブの中身
struct TabContentView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel
    // 左右の幅は自分で持つ。タブの切り替えなどで勝手に変わらないようにし、再起動後も保つ
    @AppStorage("sidebarWidth") private var sidebarWidth = 230.0
    @AppStorage("previewWidth") private var previewWidth = 300.0

    var body: some View {
        VStack(spacing: 0) {
            NavigationRow(model: model, tab: tab)
            CommandBar(model: model, tab: tab)
            Divider()
            HStack(spacing: 0) {
                if model.showSidebar {
                    SidebarView(model: model, sidebar: model.sidebar)
                        .frame(width: sidebarWidth)
                    SplitHandle(width: $sidebarWidth, range: 160...460, growsToTheRight: true)
                }
                FileListView(model: model, tab: tab)
                    .id(tab.id)
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if tab.items.isEmpty {
                            Group {
                                if tab.isLoading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    VStack(spacing: 4) {
                                        Text(tab.loadError ?? (tab.isSearching ? L("検索条件に一致する項目はありません。")
                                            : tab.isRecents ? L("最近使用した項目はありません。") : L("このフォルダーは空です。")))
                                            .font(.system(size: 13))
                                        if tab.loadError == nil, tab.isRecents {
                                            Text(L("Spotlight の索引対象外の場所は検索できません。"))
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .allowsHitTesting(false)
                        }
                    }
                if model.showPreview {
                    SplitHandle(width: $previewWidth, range: 180...640, growsToTheRight: false)
                    PreviewPane(tab: tab)
                        .frame(width: previewWidth)
                }
            }
            Divider()
            StatusBar(model: model, tab: tab)
        }
        .background(Theme.toolbar)
        .task(id: "\(tab.id)|\(tab.url.path)") {
            model.locationChanged()
        }
    }
}

/// 左右の領域の境界線。ドラッグして幅を変える
private struct SplitHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 右へドラッグしたときに幅が広がるか（左側の領域の境界なら true）
    let growsToTheRight: Bool
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .background(Theme.toolbar)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? width
                        startWidth = base
                        let delta = growsToTheRight ? value.translation.width : -value.translation.width
                        width = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

/// 時間のかかるコピーなどの進捗。キャンセルできる
struct ProgressDialog: View {
    @ObservedObject var progress: ProgressCenter

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 12) {
                Text(progress.title).font(.system(size: 13, weight: .semibold))
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progress.total > 0 ? "\(progress.done) / \(progress.total)" : "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("キャンセル")) { progress.cancel() }
                }
            }
            .padding(18)
            .frame(width: 360)
            .background(Theme.toolbar, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            .shadow(radius: 16, y: 4)
        }
    }
}
