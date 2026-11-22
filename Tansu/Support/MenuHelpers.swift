import SwiftUI
import AppKit

/// クロージャで動作を持てるメニュー項目
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true,
                     _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.handler = handler
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @objc private func fire() {
        handler?()
    }
}

extension NSMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    func addAction(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true,
                   _ handler: @escaping () -> Void) {
        addItem(ActionItem(title, symbol: symbol, checked: checked, enabled: enabled, handler))
    }

    func addSubmenu(_ title: String, symbol: String? = nil, _ build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let sub = NSMenu.make()
        build(sub)
        item.submenu = sub
        addItem(item)
    }

    func addSeparator() {
        addItem(.separator())
    }
}

/// SwiftUI のビューの位置に NSMenu などを出すための目印
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// マウスを止めたときに出す説明（ツールチップ）。
/// SwiftUI の .help はこのウィンドウでは表示されないため、AppKit の toolTip を使う
private struct ToolTipArea: NSViewRepresentable {
    let text: String

    final class AreaView: NSView {
        // クリックなどは手前の SwiftUI のビューに任せる
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AreaView {
        AreaView()
    }

    func updateNSView(_ nsView: AreaView, context: Context) {
        // 同じ文字列を入れ直すと表示までの待ち時間がやり直しになるので、変わったときだけ入れる
        let value = text.isEmpty ? nil : text
        if nsView.toolTip != value { nsView.toolTip = value }
    }
}

extension View {
    func toolTip(_ text: String) -> some View {
        background(ToolTipArea(text: text))
    }
}

/// 押すと真下に NSMenu を出すボタン
struct MenuButton<Label: View>: View {
    var help: String = ""
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var box = AnchorBox()
    @State private var hover = false

    var body: some View {
        Button {
            guard let view = box.view else { return }
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        } label: {
            label()
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AnchorView(box: box))
        .onHover { hover = $0 }
        .toolTip(help)
    }
}
