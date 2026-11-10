import SwiftUI

/// The list of virtual displays on the left, the selected one's settings on the right.
struct DisplaysTab: View {
    @EnvironmentObject private var engine: StreamEngine
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(engine.settings.displays) { display in
                        DisplayRow(config: display, status: engine.statuses[display.id], isRunning: engine.isRunning)
                            .tag(display.id)
                    }
                    .onMove { engine.settings.displays.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                listToolbar
            }
            .frame(width: 250)

            Divider()

            if let id = selection, let config = binding(for: id) {
                DisplayEditor(config: config, status: engine.statuses[id],
                              warning: engine.warnings[id], isRunning: engine.isRunning)
                    .id(id)
            } else {
                Text("Select a display")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .onAppear {
            if selection == nil { selection = engine.settings.displays.first?.id }
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 2) {
            Button(action: addDisplay) { Image(systemName: "plus").frame(width: 24, height: 20) }
                .disabled(engine.settings.displays.count >= AppSettings.maxDisplays)
                .help("Add a virtual display")
            Button(action: removeSelectedDisplay) { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(selection == nil || engine.settings.displays.count <= 1)
                .help("Remove the selected display")
            Spacer()
            Text("\(engine.settings.displays.count) of \(AppSettings.maxDisplays)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(6)
    }

    /// A binding by id rather than index, so removing a display can't leave the editor
    /// pointing past the end of the array.
    private func binding(for id: UUID) -> Binding<DisplayConfig>? {
        guard let initial = engine.settings.displays.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { engine.settings.displays.first(where: { $0.id == id }) ?? initial },
            set: { newValue in
                if let index = engine.settings.displays.firstIndex(where: { $0.id == id }) {
                    engine.settings.displays[index] = newValue
                }
            })
    }

    private func addDisplay() {
        let usedNames = Set(engine.settings.displays.map(\.name))
        var number = engine.settings.displays.count + 1
        while usedNames.contains("Virtual \(number)") { number += 1 }

        var display = DisplayConfig(name: "Virtual \(number)")
        if let last = engine.settings.displays.last {   // new displays usually match the others
            display.width = last.width
            display.height = last.height
            display.fps = last.fps
            display.mbps = last.mbps
            display.hiDPI = last.hiDPI
        }
        engine.settings.displays.append(display)
        selection = display.id
    }

    private func removeSelectedDisplay() {
        guard let id = selection,
              let index = engine.settings.displays.firstIndex(where: { $0.id == id }),
              engine.settings.displays.count > 1 else { return }
        let next = index + 1 < engine.settings.displays.count ? index + 1 : index - 1
        selection = engine.settings.displays[next].id
        engine.settings.displays.remove(at: index)
    }
}

struct DisplayRow: View {
    let config: DisplayConfig
    let status: DisplayStatus?
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .foregroundStyle(config.enabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning, let status, status.viewers > 0 {
                if let delay = status.latency?.total {
                    Text("\(Int(delay.rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Circle().fill(Color.green).frame(width: 8, height: 8).help("Viewer connected")
            }
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        guard config.enabled else { return "Off" }
        return "\(config.width) × \(config.height) · \(config.fps) Hz" + (config.hiDPI ? " · Retina" : "")
    }
}
