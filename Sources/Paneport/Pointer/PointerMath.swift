import CoreGraphics

/// Pure calculations for the pointer, kept separate so they can be unit-tested.
enum PointerMath {
    /// Stream pixels per point for a display: 2 for HiDPI, 1 otherwise.
    static func scale(displayBounds: CGRect, streamWidth: Int) -> CGFloat {
        displayBounds.width > 0 ? CGFloat(streamWidth) / displayBounds.width : 1
    }

    /// Where a global pointer location falls on a display's stream, in stream pixels,
    /// and whether it is on that display at all.
    static func streamPosition(of point: CGPoint, displayBounds: CGRect, streamWidth: Int)
        -> (position: CGPoint, isInside: Bool) {
        let s = scale(displayBounds: displayBounds, streamWidth: streamWidth)
        let position = CGPoint(x: (point.x - displayBounds.minX) * s, y: (point.y - displayBounds.minY) * s)
        return (position, displayBounds.contains(point))
    }

    /// macOS hides the pointer while you type and shows it again when the mouse moves.
    /// Mirror that: hidden when a key was pressed more recently than the mouse moved.
    static func isHiddenByTyping(secondsSinceKeyDown: Double, secondsSinceMouseMoved: Double) -> Bool {
        secondsSinceKeyDown < secondsSinceMouseMoved
    }
}
