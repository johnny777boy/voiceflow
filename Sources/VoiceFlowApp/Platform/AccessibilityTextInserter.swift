import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceFlowCore

/// Delivers text via Accessibility insertion, clipboard-restore paste, or copy-only.
/// Never pastes into a secure field.
final class AccessibilityTextInserter: TextInserting, @unchecked Sendable {

    func currentCapabilities() -> DestinationCapabilities {
        guard let focused = AX.focusedElement() else {
            // No focused element / no AX permission: fall back to clipboard paste.
            return DestinationCapabilities(supportsAccessibilityInsertion: false,
                                           allowsSyntheticPaste: true, isSecureInput: false)
        }
        let isSecure = Self.isSecure(focused)
        let settable = AX.isSettable(focused, kAXSelectedTextAttribute) || AX.isSettable(focused, kAXValueAttribute)
        return DestinationCapabilities(
            supportsAccessibilityInsertion: settable && !isSecure,
            allowsSyntheticPaste: !isSecure,
            isSecureInput: isSecure
        )
    }

    func insert(_ text: String, using strategy: InsertionStrategy) throws -> InsertionOutcome {
        // Last-moment secure-field guard (closes the TOCTOU between planning and
        // insertion): if the focused field is secure *now* — e.g. focus moved to a
        // password field within the same app after the plan was made — never AX-set
        // or synthesize a paste. Copy to the clipboard instead.
        if strategy != .copyOnly, focusedFieldIsSecure() {
            copyToClipboard(text)
            return InsertionOutcome(strategy: .copyOnly, didInsert: false,
                note: "Focused field is secure; copied to clipboard instead of inserting.")
        }

        switch strategy {
        case .accessibility:
            if insertViaAccessibility(text) {
                return InsertionOutcome(strategy: .accessibility, didInsert: true)
            }
            // Fall through to clipboard paste if AX insertion didn't take.
            return try insert(text, using: .clipboardPaste)

        case .clipboardPaste:
            do {
                try pasteWithRestore(text)
            } catch VoiceFlowError.secureFieldBlocked {
                // Field became secure between the guard above and the keystroke.
                copyToClipboard(text)
                return InsertionOutcome(strategy: .copyOnly, didInsert: false,
                    note: "Focused field is secure; copied to clipboard instead of inserting.")
            }
            return InsertionOutcome(strategy: .clipboardPaste, didInsert: true)

        case .copyOnly:
            copyToClipboard(text)
            return InsertionOutcome(strategy: .copyOnly, didInsert: false)
        }
    }

    /// Whether the *currently* focused element is a secure (password) field.
    private func focusedFieldIsSecure() -> Bool {
        guard let focused = AX.focusedElement() else { return false }
        return Self.isSecure(focused)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let role = AX.string(element, kAXRoleAttribute)
        let subrole = AX.string(element, kAXSubroleAttribute)
        return (subrole == (kAXSecureTextFieldSubrole as String)) || (role == "AXSecureTextField")
    }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Strategies

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focused = AX.focusedElement() else { return false }
        // Re-check the *specific* element we are about to write: focus may have
        // moved to a secure field since the guard in insert(). Never AX-set it.
        if Self.isSecure(focused) { return false }
        // Prefer replacing the current selection (inserts at the caret).
        if AX.isSettable(focused, kAXSelectedTextAttribute) {
            if AX.setString(focused, kAXSelectedTextAttribute, text) { return true }
        }
        // Otherwise append to the existing value.
        if AX.isSettable(focused, kAXValueAttribute) {
            let existing = AX.string(focused, kAXValueAttribute) ?? ""
            return AX.setString(focused, kAXValueAttribute, existing + text)
        }
        return false
    }

    private func pasteWithRestore(_ text: String) throws {
        // Final secure-field re-check immediately before synthesizing the paste.
        if focusedFieldIsSecure() { throw VoiceFlowError.secureFieldBlocked }

        let pb = NSPasteboard.general
        // Save the current clipboard string (best-effort).
        let previous = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Give the pasteboard a beat to settle, then paste.
        Thread.sleep(forTimeInterval: 0.03)
        guard synthesizeCommandV() else {
            throw VoiceFlowError.insertionFailed("could not synthesize paste keystroke")
        }

        // Restore the previous clipboard AFTER the target app has had time to read
        // it. Too short and slow apps (Electron) read the restored (old) clipboard.
        let restoreDelay: TimeInterval = 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pb.clearContents()
            if let previous { pb.setString(previous, forType: .string) }
        }
    }

    /// Synthesize a full Command+V sequence into the frontmost app. Posting the
    /// explicit Command key down/up (not just the flag) is more reliable across apps.
    private func synthesizeCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let cmdKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        return true
    }
}
