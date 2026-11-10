import AppKit
import SwiftUI

/// How to open the viewer on the PC, pointer behaviour, and app options.
struct ConnectTab: View {
    @EnvironmentObject private var engine: StreamEngine

    var body: some View {
        Form {
            addressSection
            pointerSection
            optionsSection
            Section("Security") {
                caption("Streams are not encrypted or password-protected. Anyone on your network who knows "
                        + "the address can watch these displays, so only use this on a network you trust.")
            }
        }
        .formStyle(.grouped)
    }

    private var addressSection: some View {
        Section("Open on your PC") {
            let urls = engine.receiverURLs
            if urls.isEmpty {
                Text("No network connection found. Connect the Mac to the same network as the PC.")
                    .foregroundStyle(.secondary)
            }
            ForEach(urls, id: \.self) { url in
                HStack {
                    Text(url).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Start streaming, then open the address above in Edge or Chrome on the PC.")
                Text("2. Save the page once (Ctrl+S, “Webpage, HTML Only”) and open the saved file from then on. "
                     + "It loads the latest version from the Mac each time.")
                Text("3. Put a browser window on each PC monitor and click the display it should show.")
                Text("Use wired connections on both computers for the lowest delay.").foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pointerSection: some View {
        Section("Mouse pointer") {
            Picker("Pointer", selection: $engine.settings.bakeCursor) {
                Text("Drawn on the PC (faster)").tag(false)
                Text("Inside the video").tag(true)
            }
            .pickerStyle(.radioGroup)
            caption(engine.settings.bakeCursor
                    ? "The pointer is part of the picture, so it moves with the video's delay and can briefly "
                        + "show on two screens when you cross between them."
                    : "The Mac sends the pointer's position the moment it moves and the PC draws it on top, so it "
                        + "has only a few milliseconds of delay and never shows on two screens. Windows you drag "
                        + "trail it slightly, and some apps' custom pointers show as a standard one.")
            Toggle("Hide the pointer while typing", isOn: $engine.settings.hidePointerWhileTyping)
                .disabled(engine.settings.bakeCursor)
            caption("Like macOS: the pointer disappears when you type and comes back when the mouse moves.")
            if engine.needsRestart {
                Text("Press Apply Changes for pointer changes to take effect.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            TextField("Web page port", value: $engine.settings.basePort, format: .number.grouping(.never))
                .disabled(engine.isRunning)
            caption("Between \(AppSettings.portRange.lowerBound) and \(AppSettings.portRange.upperBound). "
                    + "Displays stream on the next ports up (\(engine.settings.streamPort(forIndex: 0)), "
                    + "\(engine.settings.streamPort(forIndex: 1)), …). Allow incoming connections if the Mac firewall asks.")
            Toggle("Start streaming when the app opens", isOn: $engine.settings.startOnLaunch)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
