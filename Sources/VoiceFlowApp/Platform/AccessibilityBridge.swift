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

    /// Whether the app currently has Accessibility (AX) permission.
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        // Literal key value of kAXTrustedCheckOptionPrompt (avoids referencing the
        // non-Sendable global under Swift 6 strict concurrency).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
