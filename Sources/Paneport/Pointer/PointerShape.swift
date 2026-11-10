import AppKit

/// The pointer image macOS is showing, encoded for viewers.
struct PointerShape: Equatable {
    let png: Data
    /// In points.
    let size: CGSize
    /// In points, from the top-left corner of the image.
    let hotSpot: CGPoint

    /// Reads the current system pointer, falling back to the standard arrow when macOS
    /// doesn't share it (some apps' custom pointers). Call on the main thread.
    static func current() -> PointerShape? {
        if let cursor = NSCursor.currentSystem, let shape = from(cursor) { return shape }
        return from(.arrow)
    }

    static func from(_ cursor: NSCursor) -> PointerShape? {
        let image = cursor.image
        // Render at 2x so the pointer stays crisp on HiDPI streams.
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * 2, height: image.size.height * 2))
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }
        return PointerShape(png: png, size: image.size, hotSpot: cursor.hotSpot)
    }

    /// The wire message for a stream with `scale` stream pixels per point.
    func message(scale: CGFloat) -> String? {
        struct Payload: Encodable {
            let png: String
            let w, h, hx, hy: Double
        }
        let payload = Payload(
            png: png.base64EncodedString(),
            w: Double(size.width * scale), h: Double(size.height * scale),
            hx: Double(hotSpot.x * scale), hy: Double(hotSpot.y * scale))
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        return WireProtocol.pointerShape(json: String(decoding: json, as: UTF8.self))
    }
}
