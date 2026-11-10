import Foundation

/// Names, identifiers and links in one place, so the project is easy to rename or rebrand.
/// `make-app.sh` uses the same bundle identifier; keep the two in sync.
enum AppInfo {
    static let name = "Paneport"
    static let bundleIdentifier = "local.paneport"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// UserDefaults key for the saved settings. Changing it discards users' settings.
    static let settingsKey = "PaneportSettings"

    /// Shown in the menu bar menu when set.
    static let websiteURL: URL? = nil
    /// Sponsor or donation page, shown in the menu bar menu when set.
    static let supportURL: URL? = nil
}
