import SwiftUI
import AppKit

/// 「他のアプリからTansuを開く」の状態。スイッチには macOS で実際に指定されている表示先を反映する
@MainActor
final class FileViewerModel: ObservableObject {
    static let shared = FileViewerModel()
    @Published private(set) var isOn = false
    private let fileViewer = FileViewerSwitch.system

    private init() {
        refresh()
    }

    /// 実際の設定を読み直す
    func refresh() {
        isOn = fileViewer.isEnabled
    }

    /// 切り替える。失敗したら実際の状態を表示したまま、ユーザーに伝える
    func set(_ enabled: Bool) {
        let succeeded = enabled ? fileViewer.enable() : fileViewer.disable()
        refresh()
        guard !succeeded else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = enabled
            ? L("Tansuを表示先に設定できませんでした。")
            : L("表示先を元に戻せませんでした。")
        alert.informativeText = isOn
            ? L("現在、「Finderで表示」はTansuで開く設定になっています。")
            : L("現在、「Finderで表示」はTansuで開く設定になっていません。")
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    /// 初回起動時に一度だけ出す案内。「有効にする」を選んだときだけ切り替える
    func showSetupIfNeeded() {
        let key = "didShowFileViewerSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        refresh()
        guard !isOn else { return }

        let alert = NSAlert()
        alert.messageText = L("他のアプリからTansuを開く")
        alert.informativeText = L("Claudeやブラウザなど、対応するアプリの「Finderで表示」で、対象のファイルをTansuに表示します。切り替え後、開いているアプリの再起動が必要な場合があります。")
        alert.addButton(withTitle: L("有効にする"))
        alert.addButton(withTitle: L("あとで"))
        if alert.runModal() == .alertFirstButtonReturn {
            set(true)
        }
    }
}

/// 設定画面
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        FileViewerModel.shared.refresh()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = L("設定")
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: FileViewerModel.shared))
            panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 460, height: 150))
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: FileViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.isOn }, set: { model.set($0) })) {
                Text(L("他のアプリの「Finderで表示」をTansuで開く"))
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            Text(L("Claudeやブラウザなど、対応するアプリの「Finderで表示」で、対象のファイルをTansuに表示します。切り替え後、開いているアプリの再起動が必要な場合があります。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        // ほかの手段で設定が変わっていても、画面に戻ったときに実際の状態を表示する
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
