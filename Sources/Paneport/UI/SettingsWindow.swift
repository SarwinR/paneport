import AppKit
import SwiftUI

/// The main window: status and start/stop on top, settings in tabs below.
struct SettingsWindow: View {
    static let id = "settings"

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            TabView {
                DisplaysTab().tabItem { Text("Displays") }
                ArrangementTab().tabItem { Text("Arrangement") }
                ConnectTab().tabItem { Text("Connect") }
            }
            .padding(16)
        }
    }
}

/// Deep links into System Settings.
enum SystemSettingsLink {
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let displays = "x-apple.systempreferences:com.apple.Displays-Settings.extension"

    static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
