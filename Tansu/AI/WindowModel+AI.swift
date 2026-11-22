import AppKit

/// 右クリックメニューの「AI」サブメニューと、その動作
extension WindowModel {
    /// 相対パスの基準。Git リポジトリ内ならその最上位、そうでなければ表示中のフォルダ
    private var relativeBase: URL {
        tab.git?.root ?? terminalDirectory
    }

    func fillAIMenu(_ menu: NSMenu, items: [FileItem]) {
        let directory = terminalDirectory
        for agent in SettingsStore.shared.settings.agents {
            menu.addAction(L("%@で開く", agent.name), symbol: "terminal") { [weak self] in
                self?.openAgent(agent, in: directory)
            }
        }
        menu.addSeparator()
        menu.addSubmenu(L("パスのコピー"), symbol: "link") { sub in
            sub.addAction(L("絶対パス")) { [weak self] in self?.copyPaths(.absolute) }
            sub.addAction(L("相対パス")) { [weak self] in self?.copyPaths(.relative) }
            sub.addAction(L("@相対パス")) { [weak self] in self?.copyPaths(.atRelative) }
        }
        if !items.isEmpty {
            menu.addAction(L("AI用にコピー"), symbol: "doc.on.clipboard") { [weak self] in
                self?.copyForAI(items.map(\.url))
            }
        }
        menu.addAction(L("フォルダ構成をコピー"), symbol: "list.bullet.indent") { [weak self] in
            self?.copyTree(of: directory)
        }
    }

    /// 対象フォルダでターミナルを開き、エージェントのコマンドを起動する
    func openAgent(_ agent: AgentSetting, in directory: URL) {
        do {
            try Terminal.run(agent.command, in: directory)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func copyPaths(_ style: AIExport.PathStyle) {
        Clipboard.copyText(AIExport.paths(targetURLs, style: style, base: relativeBase))
        showToast(L("パスをコピーしました"))
    }

    /// 選択したファイルの内容を、見出しとコードブロックにまとめてクリップボードへ入れる
    func copyForAI(_ urls: [URL]) {
        let base = relativeBase
        Task { [weak self] in
            var files = await Task.detached(priority: .userInitiated) { AIExport.collectFiles(urls) }.value
            guard let self else { return }

            // 機密ファイルが含まれていたら、除外するかを尋ねる
            let sensitive = files.filter(AIExport.isSensitive)
            if !sensitive.isEmpty {
                switch self.confirmSensitive(sensitive, base: base) {
                case .exclude: files.removeAll(where: AIExport.isSensitive)
                case .include: break
                case .cancel: return
                }
            }
            guard !files.isEmpty else {
                self.showToast(L("コピーできるファイルがありません"))
                return
            }
            let targets = files
            let bundle = await Task.detached(priority: .userInitiated) { AIExport.markdown(for: targets, base: base) }.value
            guard bundle.included > 0 else {
                self.showToast(L("テキストファイルがないため、コピーしませんでした"))
                return
            }
            Clipboard.copyText(bundle.text)
            var message = L("%d個のファイルをAI用にコピーしました（約%@トークン）", bundle.included,
                            AIExport.formatTokens(AIExport.estimateTokens(bundle.text)))
            if !bundle.binary.isEmpty {
                message += "\n" + L("バイナリファイル%d個を除外しました", bundle.binary.count)
            }
            if !bundle.tooLarge.isEmpty {
                message += "\n" + L("大きすぎるファイル%d個を除外しました", bundle.tooLarge.count)
            }
            self.showToast(message)
        }
    }

    private enum SensitiveChoice {
        case exclude, include, cancel
    }

    private func confirmSensitive(_ files: [URL], base: URL) -> SensitiveChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("機密情報を含む可能性のあるファイルがあります")
        var names = files.prefix(8).map { AIExport.relativePath($0, to: base) }
        if files.count > 8 {
            names.append(L("ほか%d個", files.count - 8))
        }
        alert.informativeText = names.joined(separator: "\n") + "\n\n"
            + L("AIツールに貼り付けると、内容が外部へ送信されることがあります。")
        alert.addButton(withTitle: L("除外してコピー"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.addButton(withTitle: L("そのままコピー"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .exclude
        case .alertThirdButtonReturn: return .include
        default: return .cancel
        }
    }

    /// フォルダ以下の構成を tree コマンドのような図にしてクリップボードへ入れる
    func copyTree(of directory: URL) {
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { AIExport.tree(of: directory) }.value
            Clipboard.copyText(text)
            self?.showToast(L("フォルダ構成をコピーしました"))
        }
    }
}
