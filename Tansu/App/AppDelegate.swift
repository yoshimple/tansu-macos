import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [BrowserWindowController] = []
    private var keyMonitor: Any?
    private var didLaunch = false
    /// 起動が終わる前に届いた表示要求
    private var pendingReveal: [URL] = []

    /// 単体テストから起動されたときはウィンドウを出さない
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        guard !Self.isTesting else { return }
        SettingsStore.shared.load()

        // キー操作は、文字入力中でなければウィンドウ側でまとめて処理する
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let controller = event.window?.windowController as? BrowserWindowController else { return event }
            return controller.handleKeyDown(event) ? nil : event
        }

        let saved = SessionStore.load()
        if saved.isEmpty {
            openWindow(state: nil)
        } else {
            saved.forEach { openWindow(state: $0) }
        }
        NSApp.activate(ignoringOtherApps: true)

        didLaunch = true
        if !pendingReveal.isEmpty {
            reveal(pendingReveal)
            pendingReveal = []
        }
        FileViewerModel.shared.showSetupIfNeeded()
    }

    // MARK: 他のアプリからの表示要求

    /// 他のアプリの「Finderで表示」などで項目が渡されたとき。
    /// Tansu が表示先に指定されていると、macOS は対象の項目を「開く」要求として送ってくる
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty, !Self.isTesting else { return }
        if didLaunch {
            reveal(files)
        } else {
            pendingReveal += files
        }
    }

    /// Tansu を前面に出し、項目の親フォルダを開いて、その項目を選択する
    private func reveal(_ urls: [URL]) {
        let front = NSApp.mainWindow?.windowController as? BrowserWindowController
        guard let controller = front ?? controllers.last else { return }
        controller.model.reveal(urls)
        if controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(nil)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindow.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 設定ファイルを編集したあと、アプリに戻れば反映されるようにする
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isTesting else { return }
        SettingsStore.shared.load()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: ウィンドウ

    private func openWindow(state: WindowState?) {
        let controller = BrowserWindowController(state: state)
        if state?.frame == nil, let last = controllers.last?.window {
            // 2枚目以降は少しずらして重ならないようにする
            controller.window?.setFrameOrigin(NSPoint(x: last.frame.minX + 28, y: last.frame.minY - 28))
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow(state: nil)
        saveSession()
    }

    /// そのフォルダを開いた新しいウィンドウ
    func newWindow(url: URL) {
        openWindow(state: WindowState(tabs: [url.isFileURL ? url.path : url.absoluteString], selected: 0, showPreview: false))
        saveSession()
    }

    /// ブラウザ以外のウィンドウ（プロパティなど）で Cmd+W が押されたとき
    @objc func closeTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(nil)
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        // 最後の1枚は、次回起動時に復元できるよう状態を残す
        if controllers.count > 1 {
            controllers.removeAll { $0 === controller }
            saveSession()
        } else {
            saveSession()
            controllers.removeAll()
        }
    }

    func saveSession() {
        guard !controllers.isEmpty else { return }
        SessionStore.save(controllers.map(\.model.state))
    }
}
