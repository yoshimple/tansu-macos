import AppKit

struct Volume {
    let url: URL
    let name: String
    let ejectable: Bool
}

enum Volumes {
    static func list() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isRoot = url.path == "/"
            let external = !(values?.volumeIsInternal ?? true)
            let ejectable = !isRoot && ((values?.volumeIsEjectable ?? false) || (values?.volumeIsRemovable ?? false) || external)
            return Volume(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent, ejectable: ejectable)
        }
    }

    static func eject(_ url: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    /// iCloud Drive の場所（使っていなければ nil）
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Google Drive、Dropbox、OneDrive など、ファイルプロバイダのクラウドの場所
    static var cloudStorage: [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// クラウドの場所の表示名。フォルダ名は「GoogleDrive-アカウント」の形なので、サービス名だけにする
    static func cloudStorageName(_ url: URL) -> String {
        let service = String(url.lastPathComponent.split(separator: "-", maxSplits: 1).first ?? "")
        return service == "GoogleDrive" ? "Google Drive" : service
    }

    /// 2つの場所が同じボリュームにあるか
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let x = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let y = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let x, let y else { return true }
        return x.isEqual(y)
    }
}

/// フォルダの中身が変わったら知らせる
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        stop()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
