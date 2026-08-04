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
        let role = AX.string(focused, kAXRoleAttribute)
        let subrole = AX.string(focused, kAXSubroleAttribute)
        let isSecure = (subrole == (kAXSecureTextFieldSubrole as String)) || (role == "AXSecureTextField")
        let settable = AX.isSettable(focused, kAXSelectedTextAttribute) || AX.isSettable(focused, kAXValueAttribute)
        return DestinationCapabilities(
            supportsAccessibilityInsertion: settable && !isSecure,
            allowsSyntheticPaste: !isSecure,
            isSecureInput: isSecure
        )
    }

    func insert(_ text: String, using strategy: InsertionStrategy) throws -> InsertionOutcome {
        switch strategy {
        case .accessibility:
            if insertViaAccessibility(text) {
                return InsertionOutcome(strategy: .accessibility, didInsert: true)
            }
            // Fall through to clipboard paste if AX insertion didn't take.
            return try insert(text, using: .clipboardPaste)

        case .clipboardPaste:
            try pasteWithRestore(text)
            return InsertionOutcome(strategy: .clipboardPaste, didInsert: true)

        case .copyOnly:
            copyToClipboard(text)
            return InsertionOutcome(strategy: .copyOnly, didInsert: false)
        }
    }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Strategies

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focused = AX.focusedElement() else { return false }
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
        let pb = NSPasteboard.general
        // Save the current clipboard string (best-effort).
        let previous = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard synthesizeCommandV() else {
            throw VoiceFlowError.insertionFailed("could not synthesize paste keystroke")
        }

        // Restore the previous clipboard shortly after paste is delivered.
        let restoreDelay: TimeInterval = 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pb.clearContents()
            if let previous { pb.setString(previous, forType: .string) }
        }
    }

    /// Synthesize a Cmd-V keystroke into the frontmost app.
    private func synthesizeCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
