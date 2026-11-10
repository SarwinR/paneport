import CoreGraphics

/// Display arrangement: where a dragged display should land, and moving it there.
enum DisplayLayout {
    /// Displays must share at least this much edge to count as neighbours.
    static let minimumSharedEdge: CGFloat = 40
    /// Edges closer than this snap into alignment.
    static let alignThreshold: CGFloat = 40

    /// The origin closest to `proposed` at which a display of `size` touches one of
    /// `others` edge to edge without overlapping any of them. Returns `proposed`
    /// when there is nothing to snap to.
    static func snappedOrigin(size: CGSize, proposed p: CGPoint, others: [CGRect]) -> CGPoint {
        guard !others.isEmpty else { return p }
        let w = size.width, h = size.height

        func align(_ value: CGFloat, to targets: [CGFloat]) -> CGFloat {
            targets.first { abs(value - $0) < alignThreshold } ?? value
        }
        func overlapsAny(_ rect: CGRect) -> Bool {
            others.contains { other in
                let overlap = other.intersection(rect)
                return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
            }
        }

        var best = p
        var bestDistance = CGFloat.infinity
        for o in others {
            let y = align(clamp(p.y, o.minY - h + minimumSharedEdge, o.maxY - minimumSharedEdge),
                          to: [o.minY, o.maxY - h])
            let x = align(clamp(p.x, o.minX - w + minimumSharedEdge, o.maxX - minimumSharedEdge),
                          to: [o.minX, o.maxX - w])
            let candidates = [
                CGPoint(x: o.maxX, y: y),       // right of o
                CGPoint(x: o.minX - w, y: y),   // left of o
                CGPoint(x: x, y: o.maxY),       // below o
                CGPoint(x: x, y: o.minY - h),   // above o
            ]
            for c in candidates where !overlapsAny(CGRect(origin: c, size: size)) {
                let distance = hypot(c.x - p.x, c.y - p.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = c
                }
            }
        }
        return best
    }

    /// Moves a display's top-left corner to `origin` (global points). macOS remembers it.
    @discardableResult
    static func move(_ displayID: CGDirectDisplayID, to origin: CGPoint) -> Bool {
        var change: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&change) == .success else { return false }
        CGConfigureDisplayOrigin(change, displayID, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        guard CGCompleteDisplayConfiguration(change, .permanently) == .success else {
            CGCancelDisplayConfiguration(change)
            return false
        }
        return true
    }

    /// Clamps to the range between `a` and `b`, whichever order they come in.
    private static func clamp(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(value, min(a, b)), max(a, b))
    }
}
