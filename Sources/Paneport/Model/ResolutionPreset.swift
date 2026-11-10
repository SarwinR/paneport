/// Common monitor resolutions offered in the display editor.
struct ResolutionPreset: Identifiable {
    let width: Int
    let height: Int
    let label: String

    var id: String { Self.key(width: width, height: height) }

    static func key(width: Int, height: Int) -> String { "\(width)x\(height)" }

    static let all: [ResolutionPreset] = [
        .init(width: 1280, height: 720, label: "1280 × 720 (HD)"),
        .init(width: 1600, height: 900, label: "1600 × 900"),
        .init(width: 1920, height: 1080, label: "1920 × 1080 (Full HD)"),
        .init(width: 1920, height: 1200, label: "1920 × 1200"),
        .init(width: 2560, height: 1080, label: "2560 × 1080 (ultrawide)"),
        .init(width: 2560, height: 1440, label: "2560 × 1440 (QHD)"),
        .init(width: 3440, height: 1440, label: "3440 × 1440 (ultrawide)"),
        .init(width: 3840, height: 2160, label: "3840 × 2160 (4K)"),
        .init(width: 1080, height: 1920, label: "1080 × 1920 (portrait)"),
    ]
}
