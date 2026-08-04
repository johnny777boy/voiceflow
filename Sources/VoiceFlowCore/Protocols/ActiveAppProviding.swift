import Foundation

/// Abstraction over "what has focus right now" — the frontmost app, its focused
/// field, and whether that field is secure. Backed by NSWorkspace + Accessibility
/// in production.
public protocol ActiveAppProviding: AnyObject, Sendable {
    /// Capture a snapshot of the current destination for later verification.
    func captureSnapshot() -> DestinationSnapshot
}
