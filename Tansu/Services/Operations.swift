import AppKit

extension Notification.Name {
    static let clipboardChanged = Notification.Name("TansuClipboardChanged")
}

/// コピー／切り取りしたファイルの受け渡し。システムのクリップボードを使うので Finder とも行き来できる
@MainActor
final class Clipboard {
    static let shared = Clipboard()
    private let pasteboard: NSPasteboard
    private var cutURLs: Set<URL> = []
    private var cutChangeCount = -1
    private var movingChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func write(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutURLs = cut ? Set(urls) : []
        cutChangeCount = cut ? pasteboard.changeCount : -1
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    var urls: [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects as? [URL] ?? []
    }

    /// クリップボードの中身が「切り取り」によるものか
    var isCut: Bool {
        cutChangeCount == pasteboard.changeCount
    }

    var isMovingCutItems: Bool {
        movingChangeCount == pasteboard.changeCount
    }

    func beginCutPaste() -> Int? {
        guard isCut, !isMovingCutItems else { return nil }
        movingChangeCount = cutChangeCount
        return cutChangeCount
    }

    /// 移動できた分だけ取り除き、スキップ・失敗・中止で残った項目は再試行できるようにする
    func finishCutPaste(_ changeCount: Int, moved: Set<URL>) {
        if movingChangeCount == changeCount { movingChangeCount = nil }
        guard isCut, cutChangeCount == changeCount, !moved.isEmpty else { return }
        let remaining = urls.filter { !moved.contains($0) }
        if remaining.isEmpty {
            pasteboard.clearContents()
            clearCut()
        } else {
            write(remaining, cut: true)
        }
    }

    func isCutItem(_ url: URL) -> Bool {
        isCut && cutURLs.contains(url)
    }

    func clearCut() {
        guard cutChangeCount != -1 else { return }
        cutURLs = []
        cutChangeCount = -1
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// ファイル操作の「元に戻す」。全ウィンドウで共有する
@MainActor
final class UndoCenter {
    static let shared = UndoCenter()
    let manager = UndoManager()

    func register(_ name: String, _ action: @escaping @MainActor () -> Void) {
        manager.registerUndo(withTarget: self) { _ in
            MainActor.assumeIsolated { action() }
        }
        manager.setActionName(name)
    }
}

/// 時間のかかる操作の進捗。0.5秒以上かかったときだけ画面に出す
@MainActor
final class ProgressCenter: ObservableObject {
    static let shared = ProgressCenter()

    @Published private(set) var visible = false
    @Published private(set) var title = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    private var cancelHandler: (() -> Void)?
    private var showWork: DispatchWorkItem?

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    func begin(title: String, cancel: @escaping () -> Void) {
        self.title = title
        done = 0
        total = 0
        cancelHandler = cancel
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.visible = true }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func update(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    func cancel() {
        cancelHandler?()
    }

    func end() {
        showWork?.cancel()
        showWork = nil
        cancelHandler = nil
        visible = false
    }
}

/// 同名の項目があるときの確認
@MainActor
final class ConflictResolver {
    private var remembered: ConflictChoice?

    func resolve(_ url: URL) -> ConflictChoice {
        if let remembered { return remembered }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("この場所には「%@」という名前の項目が既にあります。", url.lastPathComponent)
        alert.informativeText = L("置き換える場合、元からあった項目はゴミ箱に移動します。")
        alert.addButton(withTitle: L("置き換える"))
        alert.addButton(withTitle: L("スキップする"))
        alert.addButton(withTitle: L("両方残す"))
        alert.addButton(withTitle: L("キャンセル")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("以降の項目すべてに適用する")
        let response = alert.runModal()
        let choice: ConflictChoice
        switch response {
        case .alertFirstButtonReturn: choice = .replace
        case .alertSecondButtonReturn: choice = .skip
        case .alertThirdButtonReturn: choice = .keepBoth
        default: choice = .cancel
        }
        if choice != .cancel, alert.suppressionButton?.state == .on {
            remembered = choice
        }
        return choice
    }
}
