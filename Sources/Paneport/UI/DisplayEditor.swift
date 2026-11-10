import SwiftUI

/// Settings and live stats for one virtual display.
struct DisplayEditor: View {
    @Binding var config: DisplayConfig
    let status: DisplayStatus?
    let warning: String?
    let isRunning: Bool

    @State private var isCustomResolution = false

    private static let customTag = "custom"
    private static let refreshRates = [30, 60, 75, 120]

    var body: some View {
        Form {
            Section("Display") {
                TextField("Name", text: $config.name)
                Toggle("Enabled", isOn: $config.enabled)
            }
            pictureSection
            liveSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Picture

    private var pictureSection: some View {
        Section("Picture") {
            Picker("Resolution", selection: resolutionSelection) {
                ForEach(ResolutionPreset.all) { preset in Text(preset.label).tag(preset.id) }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            if showsCustomFields {
                HStack {
                    TextField("Width", value: $config.width, format: .number.grouping(.never))
                    Text("×")
                    TextField("Height", value: $config.height, format: .number.grouping(.never))
                }
                caption("Between \(DisplayConfig.widthRange.lowerBound) × \(DisplayConfig.heightRange.lowerBound) "
                        + "and \(DisplayConfig.widthRange.upperBound) × \(DisplayConfig.heightRange.upperBound). "
                        + "Match your monitor's native resolution for the sharpest text.")
            }

            Toggle("Retina (HiDPI)", isOn: $config.hiDPI)
            caption(retinaExplanation)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Refresh rate", selection: $config.fps) {
                ForEach(Self.refreshRates, id: \.self) { rate in Text("\(rate) Hz").tag(rate) }
            }

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: quality, in: 5...80, step: 5) {
                    Text("Quality")
                } minimumValueLabel: {
                    Text("Lower").font(.caption)
                } maximumValueLabel: {
                    Text("Sharper").font(.caption)
                }
                caption("\(config.mbps) Mbit/s. Higher gives crisper text and motion but uses more network. "
                        + "20 suits 1080p; try 40 or more for 1440p, 4K and Retina.")
            }
        }
    }

    private var retinaExplanation: String {
        let looksLike = "\(config.width / 2) × \(config.height / 2)"
        return config.hiDPI
            ? "Drawn at double sharpness; the desktop looks like \(looksLike). Best on 1440p and 4K monitors."
            : "Doubles text sharpness, but the desktop then looks like \(looksLike). Best on 1440p and 4K monitors."
    }

    private var showsCustomFields: Bool {
        isCustomResolution || !matchesPreset
    }

    private var matchesPreset: Bool {
        let key = ResolutionPreset.key(width: config.width, height: config.height)
        return ResolutionPreset.all.contains { $0.id == key }
    }

    private var resolutionSelection: Binding<String> {
        Binding(
            get: {
                showsCustomFields ? Self.customTag : ResolutionPreset.key(width: config.width, height: config.height)
            },
            set: { tag in
                if tag == Self.customTag {
                    isCustomResolution = true
                } else if let preset = ResolutionPreset.all.first(where: { $0.id == tag }) {
                    isCustomResolution = false
                    config.width = preset.width
                    config.height = preset.height
                }
            })
    }

    private var quality: Binding<Double> {
        Binding(get: { Double(config.mbps) }, set: { config.mbps = Int($0) })
    }

    // MARK: - Live

    private var liveSection: some View {
        Section("Live") {
            if isRunning, let status {
                LabeledContent("Viewers", value: "\(status.viewers)")
                LabeledContent("Frames sent", value: "\(status.framesPerSecond) per second")
                if let latency = status.latency {
                    LatencyView(stats: latency)
                } else if status.viewers > 0 {
                    Text("Waiting for the viewer's first measurement…").foregroundStyle(.secondary)
                }
                caption("Frames are only sent when something on the screen changes, so a still screen shows 0.")
            } else if isRunning {
                Text("This display is off. Turn it on and press Apply Changes.").foregroundStyle(.secondary)
            } else {
                Text("Not streaming.").foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
