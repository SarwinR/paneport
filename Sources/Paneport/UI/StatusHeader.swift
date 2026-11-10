import SwiftUI

/// Streaming status, start/stop and apply buttons, and the current error, if any.
struct StatusHeader: View {
    @EnvironmentObject private var engine: StreamEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(engine.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.isRunning ? "Streaming" : "Stopped").font(.headline)
                    Text(engine.statusLine).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if engine.isBusy {
                    ProgressView().controlSize(.small)
                }
                if engine.needsRestart {
                    Button("Apply Changes") { Task { await engine.applyChanges() } }
                        .controlSize(.large)
                        .disabled(engine.isBusy)
                        .help("Restart the virtual displays with your new settings")
                }
                Button(engine.isRunning ? "Stop" : "Start Streaming") {
                    Task { await engine.toggle() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(engine.isBusy)
            }
            if let error = engine.lastError {
                errorBanner(error)
            }
        }
        .padding(16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if engine.needsScreenRecordingPermission {
                Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.screenRecording) }
            }
            Button { engine.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
