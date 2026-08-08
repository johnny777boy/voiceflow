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
    private static let denyList: Set<String> = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7", "com.1password.1password", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.lastpass.LastPass",
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

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Hard ceiling on how long any single AX call may block this thread.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute)
                ?? AX.element(appElement, kAXMainWindowAttribute) else { return nil }

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
            if Self.isSecureElement(element) { continue }
            if let role = AX.string(element, kAXRoleAttribute), Self.textRoles.contains(role) {
                for attribute in [kAXValueAttribute, kAXTitleAttribute] {
                    if let text = AX.string(element, attribute), !text.isEmpty, text.count <= 2_000 {
                        pieces.append(text)
                        characters += text.count
                        break
                    }
                }
            }
            if let children = Self.children(of: element) {
                queue.append(contentsOf: children.prefix(64))
            }
        }
        let text = pieces.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(characterCap))
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
