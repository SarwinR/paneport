import AppKit
import SwiftUI

struct PaneportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = StreamEngine()

    var body: some Scene {
        Window(AppInfo.name, id: SettingsWindow.id) {
            SettingsWindow()
                .environmentObject(engine)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 860, height: 640)

        MenuBarExtra {
            MenuBarContent().environmentObject(engine)
        } label: {
            Image(systemName: engine.isRunning ? "display.2" : "display")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from Terminal (no app bundle): act like a normal app so the window can take focus.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app lives in the menu bar, so closing the settings window doesn't quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
