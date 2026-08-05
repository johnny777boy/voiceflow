import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceFlowCore

/// Delivers text via Accessibility insertion, clipboard-restore paste, or copy-only.
/// Never pastes into a secure field.
final class AccessibilityTextInserter: TextInserting, @unchecked Sendable {

    func currentCapabilities() -> DestinationCapabilities {
        // Attempt insertion for any non-secure destination. AX role detection is
        // unreliable across apps (Notes, Electron, browsers), so we don't gate on
        // it — typing at the caret / synthetic paste posts to wherever the cursor
        // is. Only a secure (password) field is ever refused.
        guard let focused = AX.focusedElement() else {
            return DestinationCapabilities(supportsAccessibilityInsertion: false,
                                           allowsSyntheticPaste: true, isSecureInput: false)
        }
        if Self.isSecure(focused) {
            return DestinationCapabilities(supportsAccessibilityInsertion: false,
                                           allowsSyntheticPaste: false, isSecureInput: true)
        }
        let settable = AX.isSettable(focused, kAXSelectedTextAttribute) || AX.isSettable(focused, kAXValueAttribute)
        return DestinationCapabilities(
            supportsAccessibilityInsertion: settable,
            allowsSyntheticPaste: true,
            isSecureInput: false
        )
    }

    func prepareForInsertion(intoBundleIdentifier bundleIdentifier: String?) {
        guard let bundleIdentifier, bundleIdentifier != VoiceFlowInfo.bundleIdentifier else { return }
        let activate: @Sendable () -> Void = {
            let ws = NSWorkspace.shared
            // Only activate if the target isn't already frontmost (avoids stealing
            // focus unnecessarily). Fixes the case where focus drifted to VoiceFlow.
            guard ws.frontmostApplication?.bundleIdentifier != bundleIdentifier else { return }
            ws.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }?.activate()
        }
        if Thread.isMainThread { activate() } else { DispatchQueue.main.sync(execute: activate) }
        Thread.sleep(forTimeInterval: 0.08)   // let the target come to front
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
            // Wispr Flow's proven method: put the text on the clipboard, send ⌘V to
            // the focused field, then restore the previous clipboard. Works across
            // native, Electron and web fields. Typing is only a fallback for the
            // rare app that ignores synthetic ⌘V.
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
    ///
    /// Two independent signals, so we never paste into a password field even when
    /// Accessibility can't read it:
    ///  1. OS-level secure keyboard entry — password fields enable this system-wide,
    ///     and it's readable without AX. This closes the hole where `AX.focusedElement()`
    ///     is nil (no AX, or the field doesn't expose AX) but the field IS secure.
    ///  2. The focused AX element's role/subrole, when available.
    private func focusedFieldIsSecure() -> Bool {
        if IsSecureEventInputEnabled() { return true }
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

    /// Type `text` as literal Unicode keystrokes at the current caret. Uses
    /// `keyboardSetUnicodeString`, so it inserts the exact characters regardless of
    /// keyboard layout. Newlines are converted to spaces so a synthesized Return can
    /// never submit a chat box / run a command (the app must never auto-send).
    private func typeAtCursor(_ text: String) -> Bool {
        if focusedFieldIsSecure() { return false }
        let sanitized = text.replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
        let units = Array(sanitized.utf16)
        guard !units.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Post in small chunks; some apps drop very long unicode strings per event.
        let chunk = 16
        var i = 0
        while i < units.count {
            let slice = Array(units[i..<min(i + chunk, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            slice.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
            i += chunk
        }
        return true
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
        // Small gaps between events so slower apps register the keystroke.
        cmdDown.post(tap: tap); Thread.sleep(forTimeInterval: 0.01)
        vDown.post(tap: tap);   Thread.sleep(forTimeInterval: 0.01)
        vUp.post(tap: tap);     Thread.sleep(forTimeInterval: 0.01)
        cmdUp.post(tap: tap)
        return true
    }
}
