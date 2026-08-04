import Foundation
import AppKit
import ApplicationServices
import VoiceFlowCore

/// Captures the current destination: frontmost app (NSWorkspace) plus the focused
/// element's role, identifier, window title, and secure status (Accessibility).
final class WorkspaceActiveAppProvider: ActiveAppProviding, @unchecked Sendable {
    private let clock: () -> Date
    init(clock: @escaping () -> Date = { Date() }) { self.clock = clock }

    func captureSnapshot() -> DestinationSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName

        var role: String?
        var subrole: String?
        var identifier: String?
        var windowTitle: String?

        if let focused = AX.focusedElement() {
            role = AX.string(focused, kAXRoleAttribute)
            subrole = AX.string(focused, kAXSubroleAttribute)
            identifier = AX.string(focused, kAXIdentifierAttribute)
            if let window = AX.element(focused, kAXWindowAttribute) {
                windowTitle = AX.string(window, kAXTitleAttribute)
            }
        }

        let isSecure = (subrole == (kAXSecureTextFieldSubrole as String)) || (role == "AXSecureTextField")

        return DestinationSnapshot(
            bundleIdentifier: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            focusedElementRole: role,
            focusedElementIdentifier: identifier,
            isSecureInput: isSecure,
            capturedAt: clock()
        )
    }
}
