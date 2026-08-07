import Foundation
import ApplicationServices

/// Thin helpers over the AXUIElement C API for reading/writing the focused element.
enum AX {
    /// Copy a string attribute from an element.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Copy an element-valued attribute.
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Whether an attribute is settable on an element.
    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// Set a string attribute; returns whether it succeeded.
    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString) == .success
    }

    /// The system-wide focused UI element (requires Accessibility permission).
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return element(system, kAXFocusedUIElementAttribute)
    }

    /// Text-entry roles that can receive dictated text.
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// The character immediately before the caret in the focused field, if readable
    /// via Accessibility. Used to decide whether a new dictation needs a leading
    /// space so it doesn't glue onto existing text. Returns nil when unknown.
    static func characterBeforeCaret(_ element: AXUIElement) -> Character? {
        guard let value = string(element, kAXValueAttribute), !value.isEmpty else { return nil }
        // Caret location from the selected-text range (AXValue wrapping a CFRange).
        var loc = value.utf16.count   // default: assume caret at end
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
           let r = raw, CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { loc = range.location }
        }
        guard loc > 0 else { return nil }   // caret at the very start → no preceding char
        let utf16 = Array(value.utf16)
        let idx = min(loc, utf16.count) - 1
        guard idx >= 0, idx < utf16.count, let scalar = Unicode.Scalar(utf16[idx]) else { return nil }
        return Character(scalar)
    }

    /// Whether an element is an editable text destination: either it exposes a
    /// settable value/selection, or it reports a known text-entry role. This is
    /// how we tell "the caret is in a text box" from "the user is just looking at
    /// a window" — so we don't claim an insertion that has nowhere to land.
    static func isEditable(_ element: AXUIElement) -> Bool {
        if isSettable(element, kAXSelectedTextAttribute) { return true }
        if isSettable(element, kAXValueAttribute) { return true }
        if let role = string(element, kAXRoleAttribute), editableRoles.contains(role) { return true }
        return false
    }

    /// Whether the app currently has Accessibility (AX) permission.
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        // Literal key value of kAXTrustedCheckOptionPrompt (avoids referencing the
        // non-Sendable global under Swift 6 strict concurrency).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
