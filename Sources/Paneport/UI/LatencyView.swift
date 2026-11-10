import SwiftUI

/// The viewer's latency measurements: total, a bar split by stage, and the figures.
struct LatencyView: View {
    let stats: LatencyStats

    var body: some View {
        LabeledContent("Delay (Mac → PC browser)") {
            Text(Self.milliseconds(stats.total)).font(.body.monospacedDigit().weight(.semibold))
        }
        VStack(alignment: .leading, spacing: 6) {
            LatencyBar(stats: stats)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    stage("Encode on Mac", stats.encode, LatencyBar.encodeColor)
                    stage("Network", stats.network, LatencyBar.networkColor)
                }
                GridRow {
                    stage("Decode on PC", stats.decode, LatencyBar.decodeColor)
                    stage("Browser to screen", stats.browser, LatencyBar.browserColor)
                }
                if stats.pointer != nil {
                    GridRow { stage("Pointer (drawn on PC)", stats.pointer, .pink) }
                }
            }
            .font(.caption)
            Text(footer).font(.caption).foregroundStyle(.secondary)
            Text("Not included: your PC monitor's own input lag, and the Mac's drawing before capture "
                 + "(each roughly one refresh).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        let fps = Int((stats.fps ?? 0).rounded())
        let mbps = String(format: "%.1f", stats.mbps ?? 0)
        return "Network round trip \(Self.milliseconds(stats.rtt)) · \(fps) fps shown · \(mbps) Mbit/s"
            + " · \(stats.drops ?? 0) dropped"
    }

    private func stage(_ label: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
            Text(Self.milliseconds(value)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: value < 10 ? "%.1f ms" : "%.0f ms", value)
    }
}

/// One bar split into the four stages of a frame's delay.
struct LatencyBar: View {
    static let encodeColor = Color.blue
    static let networkColor = Color.green
    static let decodeColor = Color.orange
    static let browserColor = Color.purple

    let stats: LatencyStats

    var body: some View {
        let parts: [(value: Double, color: Color)] = [
            (stats.encode ?? 0, Self.encodeColor),
            (stats.network ?? 0, Self.networkColor),
            (stats.decode ?? 0, Self.decodeColor),
            (stats.browser ?? 0, Self.browserColor),
        ]
        let sum = max(parts.reduce(0) { $0 + $1.value }, 0.001)
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { index in
                    Rectangle()
                        .fill(parts[index].color)
                        .frame(width: max(0, geometry.size.width * parts[index].value / sum - 1))
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
