import Foundation

/// Spotlight（NSMetadataQuery）による、フォルダ以下のファイル名検索
@MainActor
final class SpotlightSearch {
    nonisolated static let resultLimit = 3000
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var handler: (([URL], Bool) -> Void)?
    /// 一覧に出す件数の上限
    private var limit = resultLimit

    /// 検索を始める。結果は見つかった分から順に、(場所の一覧, 完了したか) で届く
    func start(text: String, scope: URL, handler: @escaping ([URL], Bool) -> Void) {
        run(scopes: [scope],
            predicate: NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemDisplayName CONTAINS[cd] %@", text, text),
            sortDescriptors: [], limit: Self.resultLimit, handler: handler)
    }

    /// 30日以内に使ったファイルを、使った日時の新しい順に集める（Finder の「最近の項目」と同じ情報源）。フォルダとアプリは除く
    func startRecents(handler: @escaping ([URL], Bool) -> Void) {
        let since = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60) as NSDate
        let predicate = NSPredicate(
            format: "kMDItemLastUsedDate > %@ AND NOT (kMDItemContentTypeTree == %@) AND NOT (kMDItemContentTypeTree == %@)",
            since, "public.folder", "com.apple.application")
        run(scopes: [NSMetadataQueryLocalComputerScope], predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)],
            limit: 100, handler: handler)
    }

    private func run(scopes: [Any], predicate: NSPredicate, sortDescriptors: [NSSortDescriptor], limit: Int,
                     handler: @escaping ([URL], Bool) -> Void) {
        stop()
        self.handler = handler
        self.limit = limit
        query.searchScopes = scopes
        query.predicate = predicate
        query.sortDescriptors = sortDescriptors
        let center = NotificationCenter.default
        let names: [(Notification.Name, Bool)] = [
            (.NSMetadataQueryGatheringProgress, false),
            (.NSMetadataQueryDidFinishGathering, true),
            (.NSMetadataQueryDidUpdate, true),
        ]
        for (name, finished) in names {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.deliver(finished: finished) }
            })
        }
        if !query.start() {
            stop()
            handler([], true)
        }
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        handler = nil
    }

    private func deliver(finished: Bool) {
        query.disableUpdates()
        let count = min(query.resultCount, limit)
        let urls: [URL] = (0..<count).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
        query.enableUpdates()
        handler?(urls, finished)
    }
}
