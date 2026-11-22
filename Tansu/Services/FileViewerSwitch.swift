import Foundation

/// 他のアプリの「Finderで表示」を Tansu で受けるための切り替え。
///
/// macOS は、ユーザー単位の設定 NSFileViewer に指定されたアプリへ表示要求を送る。
/// 読み書きの手段を差し替えられるようにして、実際の設定に触れずにテストできるようにしている
struct FileViewerSwitch {
    /// 現在の表示先（アプリの識別子）。未指定なら nil
    var read: () -> String?
    /// 表示先を書き込む。nil は未指定に戻す
    var write: (String?) -> Void
    /// Tansu 自身の識別子
    var ownID: String
    /// 有効にする直前の表示先を覚えておく場所
    var store: UserDefaults

    private let savedKey = "fileViewerPreviousSaved"
    private let previousKey = "fileViewerPrevious"

    /// macOS で実際に Tansu が表示先に指定されているか
    var isEnabled: Bool {
        read() == ownID
    }

    /// Tansu を表示先にする。直前の表示先を覚えておく。成功したら true
    func enable() -> Bool {
        let current = read()
        if current != ownID {
            store.set(true, forKey: savedKey)
            store.set(current, forKey: previousKey)
        }
        write(ownID)
        return isEnabled
    }

    /// 表示先を、有効にする直前の状態へ戻す。
    /// すでに別のアプリが指定されている場合は、その設定に触れない。Tansu が表示先でなくなれば true
    func disable() -> Bool {
        guard isEnabled else { return true }
        let previous = store.bool(forKey: savedKey) ? store.string(forKey: previousKey) : nil
        write(previous == ownID ? nil : previous)
        guard !isEnabled else { return false }
        store.removeObject(forKey: savedKey)
        store.removeObject(forKey: previousKey)
        return true
    }
}

extension FileViewerSwitch {
    private static let key = "NSFileViewer" as CFString

    /// 実際の macOS の設定（ユーザー単位、全アプリ共通）を読み書きする
    static let system = FileViewerSwitch(
        read: {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        },
        write: { value in
            CFPreferencesSetValue(key, value as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        },
        ownID: Bundle.main.bundleIdentifier ?? "dev.tansu.Tansu",
        store: .standard)
}
