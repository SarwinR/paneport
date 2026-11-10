import Foundation

/// Errors shown to the user, with wording meant for the settings window.
enum PaneportError: LocalizedError {
    case virtualDisplayFailed(name: String)
    case displayNeverAppeared(name: String)
    case encoderUnavailable
    case invalidPort(Int)
    case screenCaptureBlocked(reason: String)

    var errorDescription: String? {
        switch self {
        case .virtualDisplayFailed(let name):
            return "Could not create “\(name)”. This macOS version may have changed the private display API."
        case .displayNeverAppeared(let name):
            return "The virtual display “\(name)” was created but never became available for capture."
        case .encoderUnavailable:
            return "The Mac's hardware video encoder could not be started."
        case .invalidPort(let port):
            return "Port \(port) can't be used. Choose a port between 1024 and 65000."
        case .screenCaptureBlocked(let reason):
            return "macOS is blocking screen capture for \(AppInfo.name) (\(reason)). "
                + "In Privacy & Security > Screen & System Audio Recording, remove any old \(AppInfo.name) entry "
                + "with the minus button, add this copy of the app with the plus button, then quit and reopen it."
        }
    }
}
