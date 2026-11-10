import AppKit
import SwiftUI

/// The menu under the menu bar icon.
struct MenuBarContent: View {
    @EnvironmentObject private var engine: StreamEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.isRunning ? "Streaming" : "Stopped")
        Text(engine.statusLine)
        Divider()
        Button(engine.isRunning ? "Stop Streaming" : "Start Streaming") {
            Task { await engine.toggle() }
        }
        .disabled(engine.isBusy)
        if engine.needsRestart {
            Button("Apply Changes") { Task { await engine.applyChanges() } }
                .disabled(engine.isBusy)
        }
        Divider()
        Button("Settings…") {
            openWindow(id: SettingsWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        if let website = AppInfo.websiteURL {
            Button("\(AppInfo.name) Website") { NSWorkspace.shared.open(website) }
        }
        if let support = AppInfo.supportURL {
            Button("Support \(AppInfo.name)…") { NSWorkspace.shared.open(support) }
        }
        Divider()
        Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
