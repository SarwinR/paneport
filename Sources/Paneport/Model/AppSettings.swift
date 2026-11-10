import Foundation

/// Everything the user can configure. Saved automatically by `SettingsStore`.
struct AppSettings: Codable, Equatable {
    static let maxDisplays = 6
    static let portRange = 1024...65000

    var displays: [DisplayConfig]
    /// The receiver page is served here; display N streams on `basePort + N`.
    var basePort = 8080
    var startOnLaunch = false
    /// true: the pointer is part of the video. false: the PC draws it from separate updates.
    var bakeCursor = false
    /// Mirrors macOS hiding the pointer while you type (only when the PC draws the pointer).
    var hidePointerWhileTyping = true

    static let defaults = AppSettings(displays: [
        DisplayConfig(name: "Virtual 1"),
        DisplayConfig(name: "Virtual 2"),
    ])

    init(displays: [DisplayConfig]) {
        self.displays = displays
    }

    /// Whether going from `running` to these settings needs the streams restarted.
    /// Settings that apply live (start on launch, hide while typing) don't.
    func requiresRestart(comparedTo running: AppSettings) -> Bool {
        displays != running.displays || basePort != running.basePort || bakeCursor != running.bakeCursor
    }

    /// Port for the stream of the `index`-th enabled display.
    func streamPort(forIndex index: Int) -> Int {
        basePort + 1 + index
    }

    // Missing keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displays = try c.decode([DisplayConfig].self, forKey: .displays)
        basePort = try c.decodeIfPresent(Int.self, forKey: .basePort) ?? 8080
        startOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? false
        bakeCursor = try c.decodeIfPresent(Bool.self, forKey: .bakeCursor) ?? false
        hidePointerWhileTyping = try c.decodeIfPresent(Bool.self, forKey: .hidePointerWhileTyping) ?? true
    }
}

/// Loads and saves `AppSettings` as JSON in UserDefaults.
struct SettingsStore {
    var defaults: UserDefaults = .standard
    var key: String = AppInfo.settingsKey
    /// Where versions from before the rename to Paneport kept their settings. Read only
    /// when nothing is saved under the current key; saving always uses the current key.
    var legacyDefaults: UserDefaults? = UserDefaults(suiteName: "local.nodisplaylink")
    var legacyKey: String = "NoDisplayLinkSettings"

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) ?? legacyDefaults?.data(forKey: legacyKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
              !settings.displays.isEmpty
        else { return .defaults }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
