import Foundation

/// Reads the text currently visible in the frontmost window, so the recognizer
/// can be biased toward the names on screen.
///
/// **Accessibility only — never a screenshot, never uploaded.** This is the
/// deliberate difference from Wispr Flow, whose screen-context feature shipped
/// user screenshots to a server. Implementations must:
/// - refuse to read secure/password contexts,
/// - refuse to read apps on a sensitive denylist (password managers),
/// - bound their own work (element budget + AX messaging timeout) so a hung app
///   can never stall a dictation.
public protocol ScreenContextProviding: Sendable {
    /// Text visible in the frontmost window, or nil when unavailable/refused.
    /// Called off the main thread, once per dictation, at record start.
    func frontmostWindowText() -> String?
}
