import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

        // Same rule as the inserter: an element whose role AND subrole both failed
        // to read is `.unreadable`, not `.notSecure`, and the system-wide flag
        // decides that case. Reading nil as "safe" here would let DestinationGuard
        // wave through a password field that hides itself from Accessibility.
        // No focused element leaves both nil, which classify() already reports as
        // .unreadable — the same answer as an element whose attributes failed to
        // read. Both mean "nothing known", and the flag decides.
        let security = FocusedFieldSecurity.classify(role: role, subrole: subrole)
        let isSecure = SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: IsSecureEventInputEnabled(),
            focusedField: security
        )

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
