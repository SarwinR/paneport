import CoreGraphics
import CVirtualDisplay
import Foundation

/// Creates virtual displays with Apple's private CGVirtualDisplay API.
///
/// A display exists only while its `CGVirtualDisplay` object is alive, and macOS
/// treats it like a real monitor: it can be arranged, gets windows and a Dock, and
/// counts nowhere near the chip's limit for physical displays.
enum VirtualDisplayFactory {
    private static let vendorID: UInt32 = 0x5050   // "PP"
    private static let productID: UInt32 = 0x4C01
    /// Only affects the reported pixel density. Roughly a 24" panel.
    private static let panelWidthMillimeters = 530.0

    static func make(_ config: DisplayConfig) -> CGVirtualDisplay? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = config.name
        descriptor.maxPixelsWide = UInt32(config.width)
        descriptor.maxPixelsHigh = UInt32(config.height)
        descriptor.sizeInMillimeters = CGSize(
            width: panelWidthMillimeters,
            height: panelWidthMillimeters * Double(config.height) / Double(config.width))
        descriptor.vendorID = vendorID
        descriptor.productID = productID
        descriptor.serialNum = config.serial

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        let refresh = CGFloat(config.fps)
        var modes = [CGVirtualDisplayMode(width: UInt(config.width), height: UInt(config.height), refreshRate: refresh)]
        if config.hiDPI {
            // macOS offers a HiDPI ("looks like") variant at half of a listed size. Listing the
            // half size too means the right variant exists however the private API reads sizes;
            // `selectMode` then picks it.
            modes.append(CGVirtualDisplayMode(
                width: UInt(config.width / 2), height: UInt(config.height / 2), refreshRate: refresh))
        }
        settings.modes = modes
        guard display.applySettings(settings) else { return nil }
        return display
    }

    /// Switches the display to the mode that draws `config` at its full pixel size: for
    /// HiDPI, the mode whose point size is half its pixel size. Returns false if macOS
    /// doesn't offer that mode, in which case the display keeps whatever mode it has.
    @discardableResult
    static func selectMode(for displayID: CGDirectDisplayID, config: DisplayConfig) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return false }
        let points = config.pointSize
        guard let mode = modes.first(where: {
            $0.pixelWidth == config.width && $0.pixelHeight == config.height
                && $0.width == points.width && $0.height == points.height
        }) else { return false }

        if let current = CGDisplayCopyDisplayMode(displayID),
           current.pixelWidth == mode.pixelWidth, current.width == mode.width {
            return true
        }
        var change: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&change) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(change, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(change, .forSession) == .success
    }
}
