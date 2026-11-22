import AppKit

/// コピー、貼り付け、削除、名前変更、新規作成など、ファイルを変更する操作
extension WindowModel {
    // MARK: コピー／切り取り／貼り付け

    func copySelection() {
        Clipboard.shared.write(tab.selectedItems.map(\.url), cut: false)
    }

    func cutSelection() {
        Clipboard.shared.write(tab.selectedItems.map(\.url), cut: true)
    }

    func paste(into directory: URL? = nil) {
        let clipboard = Clipboard.shared
        let urls = clipboard.urls
        guard !clipboard.isMovingCutItems, !urls.isEmpty, let target = directory ?? tab.directory else { return }
        let cutChangeCount = clipboard.beginCutPaste()
        transfer(urls, to: target, move: cutChangeCount != nil) { result in
            if let cutChangeCount {
                clipboard.finishCutPaste(cutChangeCount, moved: Set(result.completed.map(\.source)))
            }
        }
    }

    /// コピーまたは移動を行う。貼り付けとドラッグ＆ドロップの両方から使う
    func transfer(_ sources: [URL], to directory: URL, move: Bool,
                  onFinish: ((TransferResult) -> Void)? = nil) {
        // 「最近使用した項目」はフォルダではないので、置き先にならない
        guard !sources.isEmpty, directory.isFileURL else { return }
        let resolver = ConflictResolver()
        let progress = ProgressCenter.shared
        let task = Task.detached(priority: .userInitiated) {
            await FileOps.transfer(
                sources, to: directory, move: move,
                resolve: { url in await resolver.resolve(url) },
                progress: { done, total in
                    Task { @MainActor in progress.update(done: done, total: total) }
                })
        }
        progress.begin(title: move ? L("%d個の項目を移動しています", sources.count) : L("%d個の項目をコピーしています", sources.count)) {
            task.cancel()
        }
        Task {
            let result = await task.value
            progress.end()
            onFinish?(result)
            finish(result, move: move, directory: directory)
        }
    }

    /// ナビゲーションウィンドウなど、SwiftUI 側で受けたドロップを処理する
    func drop(_ providers: [NSItemProvider], onto target: URL) {
        let forceCopy = NSEvent.modifierFlags.contains(.option)
        Task { [weak self] in
            let urls = await Self.fileURLs(from: providers)
            // ゴミ箱へのドロップは、ゴミ箱へ移動する操作として扱う
            if target.standardizedFileURL == SidebarModel.trashURL.standardizedFileURL {
                self?.trash(urls)
                return
            }
            guard let kind = DropLogic.operation(sources: urls, target: target, forceCopy: forceCopy) else { return }
            self?.transfer(urls, to: target, move: kind == .move)
        }
    }

    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// ゴミ箱の中身を完全に削除する。取り消せないので確認してから行う
    func emptyTrash() {
        let trash = SidebarModel.trashURL
        let items = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty else {
            showToast(L("ゴミ箱は空です。"))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("ゴミ箱の%d個の項目を完全に削除しますか？", items.count)
        alert.informativeText = L("この操作は取り消せません。")
        alert.addButton(withTitle: L("ゴミ箱を空にする"))
        alert.addButton(withTitle: L("キャンセル"))
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                let failures = await Task.detached(priority: .userInitiated) {
                    items.filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
                }.value
                guard let self else { return }
                for target in self.tabs where target.url.standardizedFileURL == trash.standardizedFileURL {
                    target.reload()
                }
                if failures > 0 {
                    self.showError(L("%d個の項目を削除できませんでした。", failures))
                }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(alert.runModal())
        }
    }

    private func finish(_ result: TransferResult, move: Bool, directory: URL) {
        let pairs = result.completed
        if !pairs.isEmpty {
            UndoCenter.shared.register(move ? L("移動") : L("コピー")) { [weak self] in
                self?.performUndo { try FileOps.undoTransfer(result, move: move) }
            }
        }
        for target in tabs where target.url.path == directory.path {
            target.pendingSelection = Set(pairs.map(\.destination))
            target.reload()
        }
        sidebar.invalidate(directory)
        report(result.failures)
    }

    // MARK: 削除（ゴミ箱へ移動）

    func deleteSelection() {
        trash(tab.selectedItems.map(\.url))
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let progress = ProgressCenter.shared
        let task = Task.detached(priority: .userInitiated) {
            FileOps.trash(urls) { done, total in
                Task { @MainActor in progress.update(done: done, total: total) }
            }
        }
        progress.begin(title: L("%d個の項目をゴミ箱に移動しています", urls.count)) { task.cancel() }
        Task { [weak self] in
            guard let self else { return }
            let result = await task.value
            progress.end()
            let pairs = result.trashed
            if !pairs.isEmpty {
                UndoCenter.shared.register(L("削除")) { [weak self] in
                    self?.performUndo {
                        for pair in pairs {
                            try FileManager.default.moveItem(at: pair.trashed, to: pair.original)
                        }
                    }
                }
            }
            tab.reload()
            report(result.failures)
        }
    }

    // MARK: 名前変更

    func renameSelection() {
        guard tab.selection.count == 1, let url = tab.selection.first else { return }
        fileList?.beginRename(url)
    }

    func rename(_ url: URL, to newName: String) {
        do {
            let renamed = try FileOps.rename(url, to: newName)
            UndoCenter.shared.register(L("名前の変更")) { [weak self] in
                self?.performUndo {
                    try FileManager.default.moveItem(at: renamed, to: url)
                }
            }
            tab.pendingSelection = [renamed]
            tab.reload()
            sidebar.invalidate(tab.url)
        } catch {
            // 入力した名前を残したまま、名前の入力に戻す
            showError(error.localizedDescription) { [weak self] in
                self?.fileList?.beginRename(url, text: newName)
            }
        }
    }

    // MARK: 新規作成

    func newFolder() {
        create { try FileOps.createFolder(in: $0, name: L("新しいフォルダー")) }
    }

    func newTextFile() {
        create { try FileOps.createFile(in: $0, name: L("新しいテキスト ドキュメント") + ".txt") }
    }

    /// 作成して、そのまま名前の入力に入る
    private func create(_ make: (URL) throws -> URL) {
        guard let directory = tab.directory else { return }
        do {
            let url = try make(directory)
            UndoCenter.shared.register(L("新規作成")) { [weak self] in
                self?.performUndo {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
            tab.pendingSelection = [url]
            tab.pendingRename = url
            tab.reload()
            sidebar.invalidate(tab.url)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: 選択

    func selectAll() {
        tab.selection = Set(tab.items.map(\.url))
    }

    func deselectAll() {
        tab.selection = []
    }

    // MARK: 補助

    private func performUndo(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            showError(error.localizedDescription)
        }
        tab.reload()
    }

    func report(_ failures: [(url: URL, message: String)]) {
        guard let first = failures.first else { return }
        var message = L("「%@」を処理できませんでした。", first.url.lastPathComponent) + "\n" + first.message
        if failures.count > 1 {
            message += "\n" + L("ほかに%d個の項目でエラーが発生しました。", failures.count - 1)
        }
        showError(message)
    }
}
