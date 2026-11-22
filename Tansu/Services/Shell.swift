import Foundation

/// 外部コマンドの実行（zip、ditto、git）。バックグラウンドのスレッドから呼ぶこと
enum Shell {
    struct Output {
        let status: Int32
        let text: String
        var succeeded: Bool { status == 0 }
    }

    static func run(_ path: String, _ arguments: [String], directory: URL? = nil) -> Output {
        run(path, arguments, directory: directory, launch: { try $0.run() })
    }

    static func runCancellable(_ path: String, _ arguments: [String], directory: URL? = nil) async throws -> Output {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = run(path, arguments, directory: directory, launch: cancellation.launch)
            try Task.checkCancellation()
            return output
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func run(_ path: String, _ arguments: [String], directory: URL?,
                            launch: (Process) throws -> Void) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try launch(process)
        } catch {
            return Output(status: -1, text: error.localizedDescription)
        }
        // 先に出力を読み切る（パイプが詰まって止まるのを防ぐ）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    /// 起動前にキャンセルされた場合も、プロセスを起動したままにしない
    private final class ProcessCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func launch(_ process: Process) throws {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                try process.run()
                self.process = process
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
    }
}

enum Zip {
    struct BatchResult {
        var created: [URL] = []
        var failure: (url: URL, message: String)?
    }

    /// 項目を ZIP にまとめる。作成した ZIP の場所を返す
    static func compress(_ urls: [URL]) async throws -> URL {
        // 項目そのものではなく親フォルダを正規化する。standardizedFileURL はリンク切れの項目だけ
        // /private を外さないため、ほかの項目とパスの形がそろわず、相対パスの切り出しがずれる
        let sources = urls.map { $0.deletingLastPathComponent().standardizedFileURL.appendingPathComponent($0.lastPathComponent) }
        guard let first = sources.first else { throw FileOpsError(message: L("項目が選択されていません。")) }
        let directory = first.deletingLastPathComponent().standardizedFileURL
        let stem = urls.count == 1 ? (first.lastPathComponent as NSString).deletingPathExtension : L("アーカイブ")
        let destination = directory.appendingPathComponent((stem.isEmpty ? first.lastPathComponent : stem) + ".zip")

        // 別のフォルダにある項目は、共通の親からの相対パスで渡して区別する
        var common = directory
        for source in sources.dropFirst() {
            let parent = source.deletingLastPathComponent().standardizedFileURL
            while common.path != "/", parent.path != common.path, !FileOps.isInside(parent, common) {
                common = common.deletingLastPathComponent().standardizedFileURL
            }
        }
        let prefix = common.path == "/" ? "/" : common.path + "/"
        let paths = sources.map { String($0.path.dropFirst(prefix.count)) }
        return try await createOutput(at: destination) { staging in
            let arguments = ["-r", "-y", "-q", "-X", "-MM", "-nw", staging.path, "--"] + paths
            let output = try await Shell.runCancellable("/usr/bin/zip", arguments, directory: common)
            guard output.succeeded else {
                throw FileOpsError(message: L("圧縮できませんでした。") + "\n" + output.text)
            }
        }
    }

    /// ZIP を、同じ場所に作った同名のフォルダへ展開する。展開先のフォルダを返す
    static func extract(_ archive: URL) async throws -> URL {
        let stem = (archive.lastPathComponent as NSString).deletingPathExtension
        let destination = archive.deletingLastPathComponent().appendingPathComponent(stem)
        return try await createOutput(at: destination) { staging in
            let output = try await Shell.runCancellable("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            guard output.succeeded else {
                throw FileOpsError(message: L("展開できませんでした。") + "\n" + output.text)
            }
        }
    }

    /// エラーが出た時点で止め、取り消しに必要な展開済みフォルダも返す
    static func extractAll(_ archives: [URL]) async -> BatchResult {
        var result = BatchResult()
        for archive in archives {
            do {
                result.created.append(try await extract(archive))
            } catch is CancellationError {
                break
            } catch {
                result.failure = (archive, error.localizedDescription)
                break
            }
        }
        return result
    }

    /// 完成したものだけを同じボリューム内で公開し、中断時の作業ファイルを片付ける
    private static func createOutput(at destination: URL, write: (URL) async throws -> Void) async throws -> URL {
        try Task.checkCancellation()
        let fm = FileManager.default
        let temporary = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: temporary) }
        let staging = temporary.appendingPathComponent(destination.lastPathComponent)
        try await write(staging)
        try Task.checkCancellation()
        let output = FileOps.uniqueURL(for: destination)
        try fm.moveItem(at: staging, to: output)
        return output
    }
}
