import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 大アイコン表示と一覧表示で使うコレクションビュー
final class FileCollectionView: NSCollectionView {
    weak var controller: FileListViewController?
    /// マウスが乗っている項目の番号
    private(set) var hoveredIndex: Int?
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
        setHoveredIndex(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // スクロールでは項目がマウスの下を動くので、乗っている項目を取り直す
        refreshHover()
    }

    /// マウスの位置から、乗っている項目を取り直す
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredIndex(visibleRect.contains(point) ? indexPathForItem(at: point)?.item : nil)
    }

    private func setHoveredIndex(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredItemView?.hovered = false
        hoveredIndex = index
        hoveredItemView?.hovered = true
    }

    private var hoveredItemView: FileItemView? {
        guard let hoveredIndex, hoveredIndex < numberOfItems(inSection: 0) else { return nil }
        return (item(at: IndexPath(item: hoveredIndex, section: 0)) as? FileCollectionItem)?.itemView
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return controller?.contextMenu(forIndex: indexPathForItem(at: point)?.item, at: point, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item {
            controller?.openItem(at: index)
        }
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

final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileCollectionItem")
    let itemView = FileItemView()

    override func loadView() {
        view = itemView
    }

    override var isSelected: Bool {
        didSet { itemView.selected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { itemView.dropTarget = highlightState == .asDropTarget }
    }
}

/// コレクションビューの1項目。大アイコンは縦並び、一覧は小さいアイコンと名前の横並び
final class FileItemView: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let dots = TagDotsView()
    let badge = NSTextField(labelWithString: "")
    var url: URL?

    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            applyStyle()
        }
    }
    var selected = false {
        didSet { needsDisplay = true }
    }
    var dropTarget = false {
        didSet { needsDisplay = true }
    }
    var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    var editing = false {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        badge.alignment = .center
        for view in [icon, label, dots, badge] as [NSView] {
            addSubview(view)
        }
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: compact ? 13 : 12)
        label.alignment = compact ? .left : .center
        label.maximumNumberOfLines = compact ? 1 : 2
        // 一覧表示は1行で、文字幅どおりの大きさを返すようにする。大アイコン表示は2行まで折り返す
        label.cell?.isScrollable = compact
        label.cell?.wraps = !compact
        label.cell?.usesSingleLineMode = compact
        label.cell?.truncatesLastVisibleLine = true
        label.lineBreakMode = compact ? .byTruncatingMiddle : .byWordWrapping
        label.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let dotsWidth = dots.intrinsicContentSize.width
        let badgeWidth: CGFloat = badge.stringValue.isEmpty ? 0 : 16
        if compact {
            icon.frame = NSRect(x: 4, y: (height - 16) / 2, width: 16, height: 16)
            let left: CGFloat = 26
            let available = max(0, width - left - badgeWidth - (dotsWidth > 0 ? dotsWidth + 6 : 0) - 4)
            // ラベル自身が返す大きさは表示形式の切り替え直後に不正確なことがあるので、文字幅を直接測る
            let font = label.font ?? .systemFont(ofSize: 13)
            let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + 8
            let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
            let labelWidth = editing ? available : min(available, textWidth)
            label.frame = NSRect(x: left, y: (height - lineHeight) / 2, width: labelWidth, height: lineHeight)
            dots.frame = NSRect(x: left + labelWidth + 4, y: (height - 10) / 2, width: dotsWidth, height: 10)
            badge.frame = NSRect(x: width - badgeWidth - 2, y: (height - 14) / 2, width: badgeWidth, height: 14)
        } else {
            let iconSize: CGFloat = 64
            icon.frame = NSRect(x: (width - iconSize) / 2, y: 6, width: iconSize, height: iconSize)
            label.frame = NSRect(x: 3, y: iconSize + 10, width: width - 6, height: editing ? 18 : 32)
            dots.frame = NSRect(x: (width - iconSize) / 2 - 2, y: iconSize - 6, width: dotsWidth, height: 10)
            badge.frame = NSRect(x: (width + iconSize) / 2 - 12, y: iconSize - 8, width: badgeWidth, height: 14)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected || dropTarget || hovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        if selected || dropTarget {
            NSColor.controlAccentColor.withAlphaComponent(selected ? 0.22 : 0.12).setFill()
        } else {
            Theme.hoverFill.setFill()
        }
        path.fill()
        if dropTarget {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}

/// 大アイコン表示のサムネイル。画像・動画・PDF だけを対象にする
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    private static func wantsThumbnail(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    /// まずアイコンを返し、サムネイルができたら completion で渡す
    static func image(for url: URL, side: CGFloat, completion: @escaping (NSImage) -> Void) -> NSImage {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: side, height: side)
        guard wantsThumbnail(url) else { return icon }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                cache.setObject(image, forKey: url as NSURL)
                completion(image)
            }
        }
        return icon
    }

    static func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}
