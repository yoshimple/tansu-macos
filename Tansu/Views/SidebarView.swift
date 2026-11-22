import SwiftUI
import UniformTypeIdentifiers

/// 左側のナビゲーションウィンドウ
struct SidebarView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var sidebar: SidebarModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sidebar.rows) { row in
                        if row.separatorBefore {
                            Divider().padding(.vertical, 5).padding(.horizontal, 8)
                        }
                        SidebarRowView(model: model, sidebar: sidebar, row: row, selected: row.id == sidebar.selectedID)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .onChange(of: sidebar.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            // フォルダの中身を読み終えて、選択中の行が後から現れたとき
            .onChange(of: sidebar.revealRequest) { _, _ in
                guard let id = sidebar.selectedID else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .background(Theme.toolbar)
        // キー入力そのものは BrowserWindowController が受ける。ここではフォーカスの有無だけを持つ
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onChange(of: sidebar.hasFocus) { _, value in
            if focused != value { focused = value }
        }
        .onChange(of: focused) { _, value in
            if sidebar.hasFocus != value { sidebar.hasFocus = value }
        }
    }
}

private struct SidebarRowView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var sidebar: SidebarModel
    let row: SidebarRow
    let selected: Bool
    @State private var hover = false
    @State private var dropTargeted = false
    /// ピン留めの位置を示す線（行の上か下）
    @State private var insertion: VerticalEdge?

    private var isTrash: Bool {
        row.url?.standardizedFileURL == SidebarModel.trashURL.standardizedFileURL
    }

    private var background: Color {
        if dropTargeted { return Theme.selected }
        if selected { return sidebar.hasFocus ? Color.accentColor.opacity(0.35) : Theme.selected }
        return hover ? Theme.hover : .clear
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                sidebar.toggle(row)
            } label: {
                Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
                    .opacity(row.expandable ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!row.expandable)

            Image(systemName: row.symbol)
                .font(.system(size: 13))
                .foregroundStyle(row.symbol == "folder.fill" ? Theme.folder : Color.accentColor)
                .frame(width: 18)

            Text(row.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if row.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .toolTip(L("クイックアクセスにピン留めしています"))
            }
            if row.ejectable, let url = row.url {
                Button {
                    model.eject(url)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .toolTip(L("取り出す"))
            }
        }
        .opacity(row.missing ? 0.45 : 1)
        .toolTip(row.missing ? L("見つかりません") : "")
        .padding(.leading, CGFloat(row.depth) * 14 + 2)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(background))
        .overlay(alignment: insertion == .top ? .top : .bottom) {
            if insertion != nil {
                Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .modifier(SidebarRowAccessibility(model: model, sidebar: sidebar, row: row, selected: selected))
        .onHover { hover = $0 }
        .modifier(PinDragSource(row: row))
        .onDrop(of: [.fileURL, .plainText], delegate: SidebarDropDelegate(
            model: model, row: row, targeted: $dropTargeted, insertion: $insertion))
        // ドラッグ中にフォルダの上で1秒止めると、ツリーを展開する
        .task(id: dropTargeted) {
            guard dropTargeted else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled, dropTargeted {
                sidebar.expand(row)
            }
        }
        .onTapGesture {
            if row.url == nil {
                sidebar.toggle(row)
            }
            model.openSidebarRow(row)
        }
        .contextMenu {
            if let url = row.url {
                SidebarContextMenu(model: model, row: row, url: url, isTrash: isTrash)
            }
        }
    }
}

/// ナビゲーションウィンドウの右クリックメニュー。ファイル一覧でフォルダを右クリックしたときと並びをそろえる。
/// 対象は一覧の選択ではなく、右クリックした行のフォルダ
private struct SidebarContextMenu: View {
    let model: WindowModel
    let row: SidebarRow
    let url: URL
    let isTrash: Bool

    var body: some View {
        if row.missing {
            Button { QuickAccess.shared.toggle(url) } label: { Label(L("ピン留めを外す"), systemImage: "pin.slash") }
        } else {
            Button { model.openSidebarRow(row) } label: { Label(L("開く"), systemImage: "arrow.up.forward.app") }
            Button { model.newTab(url: url) } label: { Label(L("新しいタブで開く"), systemImage: "plus.rectangle.on.rectangle") }
            Button { (NSApp.delegate as? AppDelegate)?.newWindow(url: url) } label: {
                Label(L("新しいウィンドウで開く"), systemImage: "macwindow.badge.plus")
            }
            // 「最近使用した項目」はフォルダではないので、ここまでにする
            if url.isFileURL {
                if isTrash {
                    Divider()
                    Button { model.emptyTrash() } label: { Label(L("ゴミ箱を空にする"), systemImage: "trash.slash") }
                } else {
                    let pinned = QuickAccess.shared.isPinned(url)
                    Button { QuickAccess.shared.toggle(url) } label: {
                        Label(pinned ? L("クイックアクセスからピン留めを外す") : L("クイックアクセスにピン留め"),
                              systemImage: pinned ? "pin.slash" : "pin")
                    }
                }
                Divider()
                Button {
                    Clipboard.copyText(url.path)
                    model.showToast(L("パスをコピーしました"))
                } label: { Label(L("パスのコピー"), systemImage: "link") }
                Button { Terminal.open(url) } label: { Label(L("ターミナルで開く"), systemImage: "terminal") }
                if row.ejectable {
                    Button { model.eject(url) } label: { Label(L("取り出す"), systemImage: "eject") }
                }
                Divider()
                Button { PropertiesPanel.show([url]) } label: { Label(L("プロパティ"), systemImage: "info.circle") }
            }
        }
    }
}

/// VoiceOver 向け。行を1つの項目として読ませ、開閉状態を伝える。
/// 開閉ボタンと取り出しボタンは、行の操作（アクション）として出す
private struct SidebarRowAccessibility: ViewModifier {
    let model: WindowModel
    let sidebar: SidebarModel
    let row: SidebarRow
    let selected: Bool

    private var label: String {
        var parts = [row.title]
        if row.pinned { parts.append(L("クイックアクセスにピン留めしています")) }
        if row.missing { parts.append(L("見つかりません")) }
        return parts.joined(separator: "、")
    }

    private var value: String {
        guard row.expandable else { return "" }
        return row.expanded ? L("展開") : L("折りたたみ")
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.openSidebarRow(row) }
            .accessibilityActions {
                if row.expandable {
                    Button(row.expanded ? L("折りたたむ") : L("展開する")) { sidebar.toggle(row) }
                }
                if row.ejectable, let url = row.url {
                    Button(L("取り出す")) { model.eject(url) }
                }
            }
    }
}

/// ピン留めした行だけ、ドラッグで並べ替えられるようにする。
/// ファイルとしてではなくパスの文字列で渡し、一覧へ落としてもフォルダが移動しないようにする
private struct PinDragSource: ViewModifier {
    let row: SidebarRow

    func body(content: Content) -> some View {
        if row.pinned, row.depth == 0, let url = row.url {
            content.onDrag { NSItemProvider(object: url.path as NSString) }
        } else {
            content
        }
    }
}

/// ナビゲーションウィンドウへのドロップ。
/// ピン留めした行の上端・下端ではピン留め（並べ替え）、それ以外はそのフォルダへの移動・コピー
private struct SidebarDropDelegate: DropDelegate {
    let model: WindowModel
    let row: SidebarRow
    @Binding var targeted: Bool
    @Binding var insertion: VerticalEdge?

    private var isPinRoot: Bool {
        row.pinned && row.depth == 0
    }

    private func edge(for info: DropInfo) -> VerticalEdge? {
        guard isPinRoot else { return nil }
        let y = info.location.y
        // ピンの並べ替えは行のどこに落としても上下どちらかに入れる
        if !info.hasItemsConforming(to: [.fileURL]) {
            return y < 13 ? .top : .bottom
        }
        if y < 7 { return .top }
        if y > 19 { return .bottom }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) {
            return row.url?.isFileURL == true && !row.missing
        }
        return isPinRoot && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropExited(info: DropInfo) {
        targeted = false
        insertion = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        if insertion != nil {
            return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
        }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    private func update(_ info: DropInfo) {
        // ドロップの後にも dropUpdated が一度呼ばれ、dropExited は来ない。
        // そのまま強調すると消えずに残るので、マウスのボタンを離した後は強調しない
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            targeted = false
            insertion = nil
            return
        }
        insertion = edge(for: info)
        targeted = insertion == nil && !row.missing
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = edge(for: info)
        targeted = false
        insertion = nil
        guard let target = row.url else { return false }

        if let edge, let pinIndex = QuickAccess.shared.index(of: target) {
            let index = edge == .top ? pinIndex : pinIndex + 1
            if info.hasItemsConforming(to: [.fileURL]) {
                let providers = info.itemProviders(for: [.fileURL])
                Task { @MainActor in
                    let folders = await WindowModel.fileURLs(from: providers).filter { url in
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                        return values?.isDirectory == true && values?.isPackage != true
                    }
                    QuickAccess.shared.insert(folders, at: index)
                }
            } else {
                guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let path = object as? String else { return }
                    Task { @MainActor in
                        let url = URL(fileURLWithPath: path)
                        if QuickAccess.shared.isPinned(url) {
                            QuickAccess.shared.insert([url], at: index)
                        }
                    }
                }
            }
            return true
        }

        model.drop(info.itemProviders(for: [.fileURL]), onto: target)
        return true
    }
}
