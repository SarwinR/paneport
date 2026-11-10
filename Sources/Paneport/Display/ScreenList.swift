import AppKit

/// A display as shown on the Arrangement tab.
struct ScreenInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// Global coordinates in points; the main display's top-left corner is the origin.
    let bounds: CGRect
    let isVirtual: Bool
    let isMain: Bool
}

enum ScreenList {
    /// Active displays, excluding mirror copies. `virtualNames` names the app's own
    /// virtual displays and marks them as virtual. Call on the main thread.
    static func current(virtualNames: [CGDirectDisplayID: String]) -> [ScreenInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        var systemNames: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                systemNames[number.uint32Value] = screen.localizedName
            }
        }

        return ids.prefix(Int(count)).compactMap { id in
            if CGDisplayMirrorsDisplay(id) != 0 { return nil }
            let virtualName = virtualNames[id]
            let fallback = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"
            return ScreenInfo(
                id: id,
                name: virtualName ?? systemNames[id] ?? fallback,
                bounds: CGDisplayBounds(id),
                isVirtual: virtualName != nil,
                isMain: CGDisplayIsMain(id) != 0)
        }
    }
}
