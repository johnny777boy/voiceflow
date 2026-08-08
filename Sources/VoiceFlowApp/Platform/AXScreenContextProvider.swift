import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceFlowCore

/// Reads the frontmost window's **text** through Accessibility so the recognizer
/// can be biased toward the names the user is looking at.
///
/// This is Wispr Flow's context trick done privately: Wispr uploads screenshots
/// (their 2025 privacy incident); we read the same information from the
/// Accessibility tree, on-device, and never persist or transmit it. The text is
/// used for one thing — extracting proper nouns for the next dictation's prompt —
/// and then discarded.
///
/// Every read is bounded three ways so a slow or hostile app can never stall a
/// dictation: an AX messaging timeout, an element budget, and a character cap.
final class AXScreenContextProvider: ScreenContextProviding {

    /// Apps whose window contents we never read, even with permission. These
    /// windows are exactly where a stray string would be most sensitive, and no
    /// dictation needs their vocabulary.
    ///
    /// Entries MUST be lowercase — they are matched against a lowercased bundle
    /// ID, so a capital here silently disables the entry.
    private static let denyList: Set<String> = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7", "com.1password.1password", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.enpass-desktop",
        "com.lastpass.lastpass",
        "org.keepassxc.keepassxc",
    ]

    /// Roles that carry readable prose. Everything else in the tree is chrome.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell", "AXRow",
    ]

    private let elementBudget: Int
    private let characterCap: Int
    private let deadlineSeconds: TimeInterval

    init(elementBudget: Int = 400, characterCap: Int = 6_000, deadlineSeconds: TimeInterval = 0.4) {
        self.elementBudget = elementBudget
        self.characterCap = characterCap
        self.deadlineSeconds = deadlineSeconds
    }

    func frontmostWindowText() -> String? {
        // Never read while a secure field is active anywhere in the system.
        if IsSecureEventInputEnabled() { return nil }
        guard AX.hasAccessibilityPermission(prompt: false) else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != VoiceFlowInfo.bundleIdentifier,
              !Self.denyList.contains(bundleID.lowercased()) else { return nil }

        let appElement = Self.bounded(AXUIElementCreateApplication(app.processIdentifier))
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute).map(Self.bounded)
                ?? AX.element(appElement, kAXMainWindowAttribute).map(Self.bounded) else { return nil }

        var pieces: [String] = []
        var characters = 0
        var visited = 0
        if let title = AX.string(window, kAXTitleAttribute), !title.isEmpty {
            pieces.append(title)
            characters += title.count
        }
        // Breadth-first: the shallow nodes are the visible ones, so a budget
        // spent breadth-first collects what's on screen rather than descending
        // into one deep sidebar.
        // Three independent budgets: elements walked, characters kept, and wall
        // clock — because a single AX call against a beachballed app can burn
        // the full messaging timeout, and 400 of those would be a minute.
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var queue: [AXUIElement] = [window]
        while !queue.isEmpty, visited < elementBudget, characters < characterCap, Date() < deadline {
            let element = queue.removeFirst()
            visited += 1
            // The deadline is re-checked before every AX round-trip, not just per
            // element: each call can burn the full messaging timeout, so an
            // iteration that begins a microsecond before the deadline would
            // otherwise run half a dozen of them to completion.
            if Self.isSecureElement(element) { continue }
            guard Date() < deadline else { break }
            if let role = AX.string(element, kAXRoleAttribute), Self.textRoles.contains(role) {
                for attribute in [kAXValueAttribute, kAXTitleAttribute] {
                    guard Date() < deadline else { break }
                    if let text = AX.string(element, attribute), !text.isEmpty, text.count <= 2_000 {
                        pieces.append(text)
                        characters += text.count
                        break
                    }
                }
            }
            guard Date() < deadline else { break }
            if let children = Self.children(of: element) {
                queue.append(contentsOf: children.prefix(64).map(Self.bounded))
            }
        }
        let text = pieces.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(characterCap))
    }

    /// Cap how long any single AX round-trip on this element may block.
    ///
    /// This MUST be applied to every element we touch. The timeout binds to the
    /// one object it is set on — not to equal objects, and not to children
    /// discovered through it (only the system-wide element sets a process
    /// default). Setting it on the application element alone left every window,
    /// role and value read on the 6-second system default, which is how a single
    /// beachballed app could hold a thread for the better part of a minute
    /// despite this type's three "budgets".
    @discardableResult
    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AX.bounded(element)
    }

    private static func isSecureElement(_ element: AXUIElement) -> Bool {
        if AX.string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        return AX.string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return nil }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }
}
