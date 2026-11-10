import Foundation

/// One virtual display as the user configured it.
struct DisplayConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var enabled = true
    /// Stream size in pixels. Match the PC monitor's native resolution for the sharpest picture.
    var width = 1920
    var height = 1080
    var fps = 60
    /// Average video bitrate in Mbit/s.
    var mbps = 20
    /// Retina-style display: macOS draws at `width` × `height` pixels but lays out the
    /// desktop at half that size ("looks like"), so text is twice as sharp.
    var hiDPI = false
    /// Stable identity so macOS remembers where this display was arranged.
    var serial = UInt32.random(in: 1...UInt32.max)

    static let widthRange = 640...7680
    static let heightRange = 360...4320
    static let fpsRange = 15...120
    static let mbpsRange = 2...150
    static let defaultName = "Virtual Display"

    init(name: String) {
        self.name = name
    }

    /// Desktop size macOS lays out, in points.
    var pointSize: (width: Int, height: Int) {
        hiDPI ? (width / 2, height / 2) : (width, height)
    }

    /// A copy with every value inside the range the app supports.
    func sanitized() -> DisplayConfig {
        var c = self
        // Even sizes for the encoder; multiples of 4 for HiDPI so the half size is even too.
        let mask = hiDPI ? ~3 : ~1
        c.width = width.clamped(to: Self.widthRange) & mask
        c.height = height.clamped(to: Self.heightRange) & mask
        c.fps = fps.clamped(to: Self.fpsRange)
        c.mbps = mbps.clamped(to: Self.mbpsRange)
        if name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = Self.defaultName }
        return c
    }

    // Missing keys fall back to defaults, so settings saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        mbps = try c.decodeIfPresent(Int.self, forKey: .mbps) ?? 20
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? false
        serial = try c.decodeIfPresent(UInt32.self, forKey: .serial) ?? UInt32.random(in: 1...UInt32.max)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
