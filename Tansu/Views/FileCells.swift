import AppKit

/// カラータグの色の点
final class TagDotsView: NSView {
    var tags: [Int] = [] {
        didSet {
            guard tags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: tags.isEmpty ? 0 : CGFloat(tags.count - 1) * 6 + 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, tag) in tags.enumerated() {
            let rect = NSRect(x: CGFloat(index) * 6 + 0.5, y: 0.5, width: 9, height: 9)
            let path = NSBezierPath(ovalIn: rect)
            (Tags.colors.indices.contains(tag) ? Tags.colors[tag] : NSColor.gray).setFill()
            path.fill()
            NSColor.textBackgroundColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// 詳細表示の「名前」列のセル。アイコン、名前、タグの点、Gitの状態を並べる
final class NameCellView: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let dots = TagDotsView()
    let badge = NSTextField(labelWithString: "")

    /// 名前変更中は入力欄を列幅いっぱいに広げる
    var editing = false {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.isScrollable = true
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        badge.alignment = .center
        for view in [icon, label, dots, badge] as [NSView] {
            addSubview(view)
        }
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 4, y: (height - 16) / 2, width: 16, height: 16)
        let badgeWidth: CGFloat = badge.stringValue.isEmpty ? 0 : 18
        let dotsWidth = dots.intrinsicContentSize.width
        let left: CGFloat = 26
        let available = max(0, bounds.width - left - badgeWidth - (dotsWidth > 0 ? dotsWidth + 6 : 0) - 2)
        let labelSize = label.intrinsicContentSize
        let labelWidth = editing ? available : min(available, labelSize.width + 2)
        label.frame = NSRect(x: left, y: (height - labelSize.height) / 2, width: labelWidth, height: labelSize.height)
        dots.frame = NSRect(x: left + labelWidth + 4, y: (height - 10) / 2, width: dotsWidth, height: 10)
        badge.frame = NSRect(x: bounds.width - badgeWidth, y: (height - 14) / 2, width: badgeWidth, height: 14)
    }
}
