import Foundation

/// AI エージェントの表示名と、ターミナルで実行するコマンド
struct AgentSetting: Codable, Equatable {
    var name: String
    var command: String
}

/// 設定ファイル（~/Library/Application Support/Tansu/settings.json）の内容
struct AppSettings: Codable, Equatable {
    /// false にすると、AI サブメニュー、トークン数、Git の状態表示をまとめて非表示にする
    var aiFeaturesEnabled = true
    var agents = [
        AgentSetting(name: "Claude Code", command: "claude"),
        AgentSetting(name: "Codex", command: "codex"),
    ]

    init() {}

    /// 項目が欠けていても、既定値で補って読み込む
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aiFeaturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiFeaturesEnabled) ?? true
        if let agents = try container.decodeIfPresent([AgentSetting].self, forKey: .agents) {
            self.agents = agents
        }
    }
}

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private(set) var settings = AppSettings()

    let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tansu/settings.json")
    }()

    var aiEnabled: Bool {
        settings.aiFeaturesEnabled
    }

    /// 設定ファイルを読み込む。なければ既定値で作成する。壊れている場合は既定値で動かし、ファイルには触らない
    func load() {
        let previous = settings
        if let data = try? Data(contentsOf: fileURL) {
            settings = (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
        } else {
            settings = AppSettings()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(settings).write(to: fileURL)
        }
        if settings != previous {
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
        }
    }
}
