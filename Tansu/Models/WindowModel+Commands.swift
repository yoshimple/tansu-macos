import AppKit

/// パスのコピー、ターミナル、プロパティ、共有、ZIP など、ファイルの中身を変えない操作と ZIP
extension WindowModel {
    /// 操作の対象。選択があればその項目、なければ表示中のフォルダ
    var targetURLs: [URL] {
        let selected = tab.selectedItems.map(\.url)
        return selected.isEmpty ? (tab.directory.map { [$0] } ?? []) : selected
    }

    func copyPath() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        Clipboard.copyText(urls.map(\.path).joined(separator: "\n"))
        showToast(L("パスをコピーしました"))
    }

    /// 選択中のフォルダ（1つだけ選択している場合）か、表示中のフォルダ。
    /// 「最近使用した項目」では選択した項目の親フォルダ、選択がなければホーム
    var terminalDirectory: URL {
        let selected = tab.selectedItems
        if selected.count == 1, selected[0].isDirectory {
            return selected[0].url
        }
        if let directory = tab.directory {
            return directory
        }
        return selected.first?.url.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func openTerminal() {
        Terminal.open(terminalDirectory)
    }

    func showProperties() {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        PropertiesPanel.show(urls)
    }

    /// macOS 標準の共有メニューを出す
    func share(from view: NSView?, at rect: NSRect? = nil) {
        let urls = tab.selectedItems.map(\.url)
        guard !urls.isEmpty, let view else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: rect ?? view.bounds, of: view, preferredEdge: .minY)
    }

    func togglePin(_ url: URL) {
        QuickAccess.shared.toggle(url)
    }

    func open(_ urls: [URL], with application: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: ZIP

    func compressSelection() {
        let urls = tab.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        runArchiveTask(title: L("圧縮しています"), undoName: L("ZIPに圧縮")) {
            Zip.BatchResult(created: [try await Zip.compress(urls)])
        }
    }

    func extractSelection() {
        let archives = tab.selectedItems.map(\.url).filter { $0.pathExtension.lowercased() == "zip" }
        guard !archives.isEmpty else { return }
        runArchiveTask(title: L("展開しています"), undoName: L("ZIPを展開")) {
            await Zip.extractAll(archives)
        }
    }

    private func runArchiveTask(title: String, undoName: String,
                                _ work: @escaping @Sendable () async throws -> Zip.BatchResult) {
        let progress = ProgressCenter.shared
        let directory = tab.url
        let task = Task.detached(priority: .userInitiated) {
            do {
                return Result<Zip.BatchResult, Error>.success(try await work())
            } catch {
                return .failure(error)
            }
        }
        progress.begin(title: title) { task.cancel() }
        Task { [weak self] in
            let result = await task.value
            progress.end()
            switch result {
            case .success(let batch):
                let created = batch.created
                if !created.isEmpty {
                    UndoCenter.shared.register(undoName) { [weak self] in
                        let result = FileOps.trash(created)
                        self?.tab.reload()
                        self?.report(result.failures)
                    }
                }
                guard let self else { return }
                for target in self.tabs where target.url.path == directory.path {
                    target.pendingSelection = created.isEmpty ? nil : Set(created)
                    target.reload()
                }
                self.sidebar.invalidate(directory)
                if let failure = batch.failure {
                    let detail = created.isEmpty ? failure.message
                        : L("%d個のZIPを展開しました。⌘Zで取り消せます。", created.count) + "\n" + failure.message
                    self.report([(failure.url, detail)])
                }
            case .failure(let error):
                if !(error is CancellationError) { self?.showError(error.localizedDescription) }
            }
        }
    }

    // MARK: ヘルプ

    func showShortcuts() {
        let rows: [(String, String)] = [
            (L("開く"), "Enter"),
            (L("名前の変更"), "F2"),
            (L("上の階層へ"), "⌫ / Option+↑"),
            (L("戻る／進む"), "Option+← / Option+→, Cmd+[ / Cmd+]"),
            (L("削除（ゴミ箱へ）"), "Cmd+⌫ / fn+⌫"),
            (L("コピー／切り取り／貼り付け"), "Cmd+C / Cmd+X / Cmd+V"),
            (L("元に戻す"), "Cmd+Z"),
            (L("すべて選択"), "Cmd+A"),
            (L("新しいフォルダー"), "Cmd+Shift+N"),
            (L("アドレスバーへ移動"), "Cmd+L / Option+D"),
            (L("検索"), "Cmd+F / Cmd+E"),
            (L("更新"), "F5 / Cmd+R"),
            (L("新しいタブ／タブを閉じる"), "Cmd+T / Cmd+W"),
            (L("新しいウィンドウ"), "Cmd+N"),
            (L("プロパティ"), "Option+Enter / Cmd+I"),
            (L("プレビューウィンドウ"), "Option+P"),
            (L("クイックルック"), "Space"),
        ]
        let alert = NSAlert()
        alert.messageText = L("キー操作の一覧")
        alert.informativeText = rows.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        alert.addButton(withTitle: L("OK"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

enum Terminal {
    private static let application = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    /// macOS 標準のターミナルで、そのフォルダを開く
    static func open(_ directory: URL) {
        NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    /// そのフォルダでコマンドを実行する。終了後もシェルを残して、結果やエラーを読めるようにする
    static func run(_ command: String, in directory: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tansu", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("run-\(UUID().uuidString).command")
        func quote(_ text: String) -> String {
            "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // 対話シェル経由で実行して、.zshrc のエイリアスや PATH を使えるようにする
        let body = """
        #!/bin/zsh
        rm -f -- "$0"
        cd -- \(quote(directory.path)) || exit 1
        clear
        "${SHELL:-/bin/zsh}" -i -c \(quote(command))
        exec "${SHELL:-/bin/zsh}" -l

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
