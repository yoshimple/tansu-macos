import AppKit
import SwiftUI
import Quartz

final class FileTableView: NSTableView {
    weak var controller: FileListViewController?
    /// マウスが乗っている行（なければ -1）
    private(set) var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverArea.map(removeTrackingArea)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // スクロールでは行がマウスの下を動くので、乗っている行を取り直す
        refreshHover()
    }

    /// マウスの位置から、乗っている行を取り直す
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(visibleRect.contains(point) ? row(at: point) : -1)
    }

    private func setHoveredRow(_ row: Int) {
        guard row != hoveredRow else { return }
        hoveredRowView?.hovered = false
        hoveredRow = row
        hoveredRowView?.hovered = true
    }

    private var hoveredRowView: FileRowView? {
        guard hoveredRow >= 0, hoveredRow < numberOfRows else { return nil }
        return rowView(atRow: hoveredRow, makeIfNecessary: false) as? FileRowView
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return controller?.contextMenu(forIndex: row >= 0 ? row : nil, at: point, in: self)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        controller?.springLoad(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.springLoad(nil)
    }
}

/// 詳細表示の1行。マウスが乗っている間は背景色を変える
final class FileRowView: NSTableRowView {
    var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovered, !isSelected else { return }
        Theme.hoverFill.setFill()
        bounds.fill()
    }
}

/// 中央のファイル一覧。TabModel の内容を表示し、選択や並べ替えを TabModel に返す。
/// 詳細表示は NSTableView、大アイコン表示と一覧表示は NSCollectionView を使う
@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate,
    @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let textCell = NSUserInterfaceItemIdentifier("text")
    }

    let model: WindowModel
    let tab: TabModel

    private(set) var items: [FileItem] = []
    private var indexByURL: [URL: Int] = [:]
    private var loadedVersion = -1
    private var shownMode: ViewMode?
    private var shownGit: GitInfo?
    private var syncing = false

    private let tableScroll = NSScrollView()
    let tableView = FileTableView()
    private let collectionScroll = NSScrollView()
    let collectionView = FileCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()

    private var renamingURL: URL?
    private var renameCancelled = false
    private var observers: [NSObjectProtocol] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMdd HHmm")
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(model: WindowModel, tab: TabModel) {
        self.model = model
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        view = NSView()
        setUpTable()
        setUpCollection()
        for name in [Notification.Name.prefsChanged, .clipboardChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.redisplay() }
            })
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focus()
    }

    private func setUpTable() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, SortKey)] = [
            (Column.name, L("名前"), 320, .name),
            (Column.modified, L("更新日時"), 150, .modified),
            (Column.kind, L("種類"), 160, .kind),
            (Column.size, L("サイズ"), 90, .size),
        ]
        for (identifier, title, width, key) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = identifier == Column.name ? 120 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.controller = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 10, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsTypeSelect = false
        // 幅が足りないときは名前の列を縮め、種類とサイズを画面内に残す
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.autosaveName = "FileListColumns"
        tableView.autosaveTableColumns = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        embed(tableView, in: tableScroll)
        tableScroll.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tableScroll, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fitNameColumn() }
        })
    }

    /// 列が表示幅からはみ出していたら、名前の列を縮めて収める。
    /// 保存した列幅が今の幅より広いまま復元されると、名前の列がウィンドウの幅に追従しなくなり、種類やサイズが画面外に残るため
    private func fitNameColumn() {
        let visible = tableScroll.contentSize.width
        let excess = tableView.frame.width - visible
        guard visible > 0, excess > 0.5, let name = tableView.tableColumns.first else { return }
        name.width = max(name.minWidth, name.width - excess)
    }

    private func setUpCollection() {
        collectionView.controller = self
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.textBackgroundColor]
        collectionView.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        embed(collectionView, in: collectionScroll)
        collectionScroll.isHidden = true
    }

    private func embed(_ document: NSView, in scroll: NSScrollView) {
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.width, .height]
        view.addSubview(scroll)
    }

    private var isDetails: Bool {
        tab.viewMode == .details
    }

    private var activeView: NSView {
        isDetails ? tableView : collectionView
    }

    // MARK: モデルとの同期

    /// SwiftUI 側から、TabModel が変わるたびに呼ばれる
    func update() {
        guard renamingURL == nil else { return }
        let modeChanged = shownMode != tab.viewMode
        if modeChanged {
            applyMode()
        }
        if modeChanged || loadedVersion != tab.itemsVersion || shownGit != tab.git {
            shownGit = tab.git
            loadedVersion = tab.itemsVersion
            items = tab.items
            indexByURL = Dictionary(items.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
            reloadActiveView()
        }
        applySort()
        applySelection()
        refreshQuickLook()
        if let url = tab.pendingRename?.normalizedFile, indexByURL[url] != nil {
            tab.pendingRename = nil
            DispatchQueue.main.async { [weak self] in self?.beginRename(url) }
        }
    }

    /// 表示形式を切り替える
    private func applyMode() {
        let responder = view.window?.firstResponder
        let hadFocus = responder === tableView || responder === collectionView
        shownMode = tab.viewMode
        tableScroll.isHidden = !isDetails
        collectionScroll.isHidden = isDetails
        switch tab.viewMode {
        case .details:
            break
        case .icons:
            flowLayout.scrollDirection = .vertical
            flowLayout.itemSize = NSSize(width: 104, height: 112)
            flowLayout.minimumInteritemSpacing = 6
            flowLayout.minimumLineSpacing = 6
            flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        case .list:
            // 上から下へ並べ、あふれたら右の列へ進む
            flowLayout.scrollDirection = .horizontal
            flowLayout.itemSize = NSSize(width: 250, height: 22)
            flowLayout.minimumInteritemSpacing = 0
            flowLayout.minimumLineSpacing = 12
            flowLayout.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        }
        if hadFocus {
            focus()
        }
    }

    private func reloadActiveView() {
        // 中身が変わると、マウスの下にある項目も変わる
        if isDetails {
            tableView.reloadData()
            tableView.refreshHover()
        } else {
            collectionView.reloadData()
            collectionView.refreshHover()
        }
    }

    /// 表示設定（拡張子の表示など）や切り取り状態が変わったときの描き直し
    func redisplay() {
        guard renamingURL == nil else { return }
        reloadActiveView()
        applySelection()
    }

    private func applySort() {
        if tab.usesQueryOrder {
            if !tableView.sortDescriptors.isEmpty { tableView.sortDescriptors = [] }
            return
        }
        let descriptor = NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.sortAscending)
        let current = tableView.sortDescriptors.first
        if current?.key != descriptor.key || current?.ascending != descriptor.ascending {
            tableView.sortDescriptors = [descriptor]
        }
    }

    private func applySelection() {
        let indexes = tab.selection.compactMap { indexByURL[$0] }
        syncing = true
        defer { syncing = false }
        if isDetails {
            let rows = IndexSet(indexes)
            guard rows != tableView.selectedRowIndexes else { return }
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first {
                tableView.scrollRowToVisible(first)
            }
        } else {
            let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
            guard paths != collectionView.selectionIndexPaths else { return }
            collectionView.selectionIndexPaths = paths
            if let first = paths.min() {
                collectionView.scrollToItems(
                    at: [first], scrollPosition: tab.viewMode == .list ? .nearestVerticalEdge : .nearestHorizontalEdge)
            }
        }
    }

    private func selectionChanged(_ indexes: [Int]) {
        guard !syncing else { return }
        let urls = Set(indexes.compactMap { $0 < items.count ? items[$0].url : nil })
        if tab.selection != urls {
            tab.selection = urls
        }
    }

    // MARK: クイックルック

    private var quickLookURLs: [URL] = []

    /// Space キーで、選択中のファイルを開かずにプレビューする
    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if !tab.selection.isEmpty {
            focus()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// パネルを開いたまま選択を変えたら、プレビューも切り替える
    private func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        let urls = tab.selectedItems.map(\.url)
        if urls != quickLookURLs {
            quickLookURLs = urls
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookURLs = tab.selectedItems.map(\.url)
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    /// パネルを開いたまま矢印キーで一覧の選択を動かせるようにする
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        activeView.keyDown(with: event)
        return true
    }

    func focus() {
        view.window?.makeFirstResponder(activeView)
    }

    func openItem(at index: Int) {
        guard index >= 0, index < items.count else { return }
        if tab.selection.contains(items[index].url) {
            model.openSelection()
        } else {
            model.open([items[index]])
        }
    }

    /// 名前の横に出す Git の状態
    private func gitBadge(for item: FileItem) -> (text: String, color: NSColor)? {
        guard let mark = tab.git?.status(for: item.url) else { return nil }
        switch mark {
        case "A": return (mark, .systemGreen)
        case "?": return (mark, .secondaryLabelColor)
        default: return (mark, .systemOrange)
        }
    }

    private func alpha(for item: FileItem) -> CGFloat {
        Clipboard.shared.isCutItem(item.url) ? 0.4 : (item.isHidden ? 0.55 : 1)
    }

    // MARK: NSTableView（詳細表示）

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRowView()
        view.hovered = row == self.tableView.hoveredRow
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < items.count else { return nil }
        let item = items[row]
        if column.identifier == Column.name {
            let cell = tableView.makeView(withIdentifier: Column.name, owner: nil) as? NameCellView ?? {
                let cell = NameCellView()
                cell.identifier = Column.name
                return cell
            }()
            let image = NSWorkspace.shared.icon(forFile: item.url.path)
            image.size = NSSize(width: 16, height: 16)
            cell.icon.image = image
            cell.label.stringValue = item.label(showExtensions: Prefs.shared.showExtensions)
            cell.dots.tags = item.tags
            let badge = gitBadge(for: item)
            cell.badge.stringValue = badge?.text ?? ""
            cell.badge.textColor = badge?.color
            cell.alphaValue = alpha(for: item)
            cell.editing = false
            cell.needsLayout = true
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Column.textCell, owner: nil) as? NSTableCellView ?? Self.makeTextCell()
        let field = cell.textField
        switch column.identifier {
        case Column.modified:
            field?.stringValue = item.modified.map(Self.dateFormatter.string(from:)) ?? ""
            field?.alignment = .left
        case Column.kind:
            field?.stringValue = item.kind
            field?.alignment = .left
        default:
            field?.stringValue = item.isDirectory ? "" : Self.sizeFormatter.string(fromByteCount: item.size)
            field?.alignment = .right
        }
        return cell
    }

    private static func makeTextCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Column.textCell
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged(Array(tableView.selectedRowIndexes))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        tab.setSort(key, ascending: descriptor.ascending)
    }

    @objc private func doubleClicked() {
        openItem(at: tableView.clickedRow)
    }

    // MARK: NSCollectionView（大アイコン表示、一覧表示）

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier, for: indexPath)
        guard let cell = cell as? FileCollectionItem, indexPath.item < items.count else { return cell }
        let item = items[indexPath.item]
        let view = cell.itemView
        view.hovered = indexPath.item == self.collectionView.hoveredIndex
        let compact = tab.viewMode == .list
        view.compact = compact
        view.url = item.url
        view.label.stringValue = item.label(showExtensions: Prefs.shared.showExtensions)
        view.dots.tags = item.tags
        let badge = gitBadge(for: item)
        view.badge.stringValue = badge?.text ?? ""
        view.badge.textColor = badge?.color
        view.alphaValue = alpha(for: item)
        view.editing = false
        if compact {
            let image = NSWorkspace.shared.icon(forFile: item.url.path)
            image.size = NSSize(width: 16, height: 16)
            view.icon.image = image
        } else {
            // 画像はサムネイルができしだい差し替える
            let url = item.url
            view.icon.image = Thumbnails.image(for: url, side: 64) { [weak view] image in
                if view?.url == url { view?.icon.image = image }
            }
        }
        view.needsLayout = true
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged(collectionView.selectionIndexPaths.map(\.item))
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged(collectionView.selectionIndexPaths.map(\.item))
    }

    // MARK: 右クリックメニューと共有

    private weak var menuView: NSView?
    private var menuPoint = NSPoint.zero

    func contextMenu(forIndex index: Int?, at point: NSPoint, in view: NSView) -> NSMenu {
        menuView = view
        menuPoint = point
        guard let index, index < items.count else {
            tab.selection = []
            return ContextMenu.forBackground(model: model)
        }
        // 選択外の項目を右クリックしたら、その項目だけを選択する
        let url = items[index].url
        if !tab.selection.contains(url) {
            tab.selection = [url]
            applySelection()
        }
        return ContextMenu.forItems(model: model, items: tab.selectedItems)
    }

    /// 右クリックした位置に共有メニューを出す
    func shareSelection() {
        model.share(from: menuView ?? view, at: NSRect(origin: menuPoint, size: NSSize(width: 1, height: 1)))
    }

    // MARK: ドラッグ＆ドロップ

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        row < items.count ? items[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // フォルダの行の上ならそのフォルダへ、それ以外は表示中のフォルダへ
        let folderRow = folderIndex(atWindowPoint: info.draggingLocation) ?? -1
        tableView.setDropRow(folderRow, dropOperation: .on)
        springLoad(folderRow >= 0 ? items[folderRow].url : nil)
        return dragOperation(for: info, target: folderRow >= 0 ? items[folderRow].url : tab.url)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = row >= 0 && row < items.count ? items[row].url : tab.url
        return performDrop(info, target: target)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.item < items.count ? items[indexPath.item].url as NSURL : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        var target = tab.url
        if let index = folderIndex(atWindowPoint: draggingInfo.draggingLocation) {
            target = items[index].url
            proposedDropIndexPath.pointee = NSIndexPath(forItem: index, inSection: 0)
            proposedDropOperation.pointee = .on
            springLoad(target)
        } else {
            proposedDropIndexPath.pointee = NSIndexPath(forItem: items.count, inSection: 0)
            proposedDropOperation.pointee = .before
            springLoad(nil)
        }
        return dragOperation(for: draggingInfo, target: target)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let onFolder = dropOperation == .on && indexPath.item < items.count
        return performDrop(draggingInfo, target: onFolder ? items[indexPath.item].url : tab.url)
    }

    /// ウィンドウ座標の位置にあるフォルダの番号。フォルダの上でなければ nil（表示中のフォルダがドロップ先になる）
    func folderIndex(atWindowPoint location: NSPoint) -> Int? {
        let index = isDetails
            ? tableView.row(at: tableView.convert(location, from: nil))
            : collectionView.indexPathForItem(at: collectionView.convert(location, from: nil))?.item ?? -1
        return index >= 0 && index < items.count && items[index].isDirectory ? index : nil
    }

    private static func urls(from info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects as? [URL] ?? []
    }

    private func dropKind(for info: NSDraggingInfo, target: URL) -> DropOperation? {
        // 「最近使用した項目」の空白部分にはドロップできない
        guard target.isFileURL else { return nil }
        let optionPressed = NSEvent.modifierFlags.contains(.option)
            || NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let forceCopy = DropLogic.forcesCopy(sourceMask: info.draggingSourceOperationMask, optionPressed: optionPressed)
        return DropLogic.operation(sources: Self.urls(from: info), target: target, forceCopy: forceCopy)
    }

    private func dragOperation(for info: NSDraggingInfo, target: URL) -> NSDragOperation {
        switch dropKind(for: info, target: target) {
        case .move: return .move
        case .copy: return .copy
        case nil: return []
        }
    }

    private func performDrop(_ info: NSDraggingInfo, target: URL) -> Bool {
        springLoad(nil)
        guard let kind = dropKind(for: info, target: target) else { return false }
        model.transfer(Self.urls(from: info), to: target, move: kind == .move)
        return true
    }

    private var springTarget: URL?
    private var springTimer: Timer?

    /// ドラッグ中にフォルダの上で1秒止めると、そのフォルダを開く
    func springLoad(_ url: URL?) {
        guard url != springTarget else { return }
        springTimer?.invalidate()
        springTarget = url
        guard let url else { return }
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.springTarget == url else { return }
                self.springTarget = nil
                self.tab.navigate(to: url)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    // MARK: 先頭の文字にジャンプ

    private var typed = ""
    private var lastTyped = Date.distantPast

    func typeSelect(_ characters: String) {
        let now = Date()
        typed = now.timeIntervalSince(lastTyped) > 1 ? characters : typed + characters
        lastTyped = now
        let showExtensions = Prefs.shared.showExtensions
        let match = items.first {
            $0.label(showExtensions: showExtensions).range(of: typed, options: [.anchored, .caseInsensitive, .widthInsensitive]) != nil
        }
        if let match {
            tab.selection = [match.url]
        }
    }

    // MARK: 名前変更

    /// 一覧の中で名前の入力を始める。拡張子を除いた部分だけを選択状態にする
    /// text を渡すと、その文字列を入れた状態で入力を始める（名前変更に失敗したときの再入力用）
    func beginRename(_ url: URL, text: String? = nil) {
        guard renamingURL == nil, let index = indexByURL[url] else { return }
        let item = items[index]
        if isDetails {
            tableView.scrollRowToVisible(index)
            guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? NameCellView else { return }
            cell.editing = true
            cell.layoutSubtreeIfNeeded()
            startEditing(cell.label, item: item, text: text)
        } else {
            let path = IndexPath(item: index, section: 0)
            collectionView.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
            collectionView.layoutSubtreeIfNeeded()
            guard let cell = collectionView.item(at: path) as? FileCollectionItem else { return }
            cell.itemView.editing = true
            cell.itemView.layoutSubtreeIfNeeded()
            startEditing(cell.itemView.label, item: item, text: text)
        }
    }

    private func startEditing(_ field: NSTextField, item: FileItem, text: String? = nil) {
        renamingURL = item.url
        renameCancelled = false
        field.stringValue = text ?? item.name
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        view.window?.makeFirstResponder(field)
        let name = field.stringValue as NSString
        let stemLength = item.isDirectory ? name.length : (name.deletingPathExtension as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: stemLength > 0 ? stemLength : name.length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            focus()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renamingURL else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.delegate = nil
        renamingURL = nil
        if let index = indexByURL[url], index < items.count {
            field.stringValue = items[index].label(showExtensions: Prefs.shared.showExtensions)
        }
        (field.superview as? NameCellView)?.editing = false
        (field.superview as? FileItemView)?.editing = false
        if !renameCancelled, !newName.isEmpty, newName != url.lastPathComponent {
            model.rename(url, to: newName)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.view.window?.firstResponder === self.view.window {
                self.focus()
            }
            self.update()
        }
    }
}

/// FileListViewController を SwiftUI に載せる
struct FileListView: NSViewControllerRepresentable {
    @ObservedObject var model: WindowModel
    @ObservedObject var tab: TabModel

    func makeNSViewController(context: Context) -> FileListViewController {
        let controller = FileListViewController(model: model, tab: tab)
        model.fileList = controller
        return controller
    }

    func updateNSViewController(_ controller: FileListViewController, context: Context) {
        controller.update()
    }
}
