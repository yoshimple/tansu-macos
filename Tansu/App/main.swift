import AppKit

MainActor.assumeIsolated {
    // 編集メニューに自動で追加される「音声入力」「絵文字と記号」を出さない（メニューは最低限にする）
    UserDefaults.standard.register(defaults: [
        "NSDisabledDictationMenuItem": true,
        "NSDisabledCharacterPaletteMenuItem": true,
    ])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
