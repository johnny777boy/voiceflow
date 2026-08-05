import Foundation

/// An immutable capture of *where* dictation was initiated. Taken at recording
/// start and compared again immediately before insertion so text is never
/// delivered into the wrong place (destination protection).
public struct DestinationSnapshot: Codable, Sendable, Equatable, Hashable {
    /// Bundle identifier of the frontmost application (e.g. `com.apple.Terminal`).
    public let bundleIdentifier: String?
    /// Human-readable application name for display / history.
    public let appName: String?
    /// Title of the focused window, when available via Accessibility.
    public let windowTitle: String?
    /// Accessibility role of the focused UI element (e.g. `AXTextArea`).
    public let focusedElementRole: String?
    /// A stable-ish identifier for the focused element, when the system exposes one.
    public let focusedElementIdentifier: String?
    /// True when the focused field is secure (password field) — insertion is forbidden.
    public let isSecureInput: Bool
    /// When this snapshot was captured.
    public let capturedAt: Date

    public init(
        bundleIdentifier: String?,
        appName: String?,
        windowTitle: String?,
        focusedElementRole: String?,
        focusedElementIdentifier: String?,
        isSecureInput: Bool,
        capturedAt: Date
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElementRole = focusedElementRole
        self.focusedElementIdentifier = focusedElementIdentifier
        self.isSecureInput = isSecureInput
        self.capturedAt = capturedAt
    }

    /// Whether two snapshots refer to the same insertion destination.
    ///
    /// The **application identity** is the destination guarantee (don't insert into
    /// a different app). Field-level signals — window title, element role/identifier
    /// — are intentionally NOT required to match: they change constantly and, in
    /// Electron/web apps (Claude Code, Slack, browsers), differ between capture and
    /// insertion, which would wrongly reject a valid destination and divert to the
    /// clipboard. Secure-field protection is handled separately by the guard.
    public func matches(_ other: DestinationSnapshot) -> Bool {
        bundleIdentifier == other.bundleIdentifier
    }
}
