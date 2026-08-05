import Foundation
import AppKit
import VoiceFlowCore

/// System-wide push-to-talk / toggle hotkey via `NSEvent` monitors (global +
/// local). This is simpler and more reliable than a CGEvent tap for observing
/// key/modifier events; it requires Accessibility permission. It does not consume
/// events, which is fine for a pure-modifier hold (e.g. Option) that never types.
final class GlobalHotkeyManager: HotkeyManaging, @unchecked Sendable {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var configuration: HotkeyConfiguration?
    private var handler: (@Sendable (HotkeyEvent) -> Void)?
    private var isChordDown = false

    /// Whether monitors are installed.
    var isActive: Bool { globalMonitor != nil || localMonitor != nil }

    func register(_ configuration: HotkeyConfiguration, handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        unregister()
        self.configuration = configuration
        self.handler = handler

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        // Global monitor: fires when OTHER apps are focused (needs Accessibility).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
        }
        // Local monitor: fires when VoiceFlow itself is focused.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.process(event)
            return event
        }
        Log.hotkey.notice("hotkey monitors installed for \(configuration.displayString, privacy: .public) (global=\(self.globalMonitor != nil), local=\(self.localMonitor != nil))")
    }

    func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        configuration = nil
        handler = nil
        isChordDown = false
    }

    // MARK: - Event handling

    private func process(_ event: NSEvent) {
        guard let config = configuration, let handler else { return }

        // Pure single-key / modifier hold (keyCode == nil): driven by flag changes.
        if config.keyCode == nil {
            guard event.type == .flagsChanged else { return }
            let present = Self.modifierSet(from: event)
            let required = HotkeyMatcher.decode(carbonMask: config.modifierFlags)
            let modsOK = HotkeyMatcher.matches(required: required, present: present)
            if config.isPushToTalk {
                if modsOK && !isChordDown { isChordDown = true; handler(.pressed) }
                else if !modsOK && isChordDown { isChordDown = false; handler(.released) }
            } else if modsOK && !isChordDown {
                isChordDown = true; handler(.toggled)
            } else if !modsOK {
                isChordDown = false
            }
            return
        }

        // Keyed hotkey (a normal key, optionally with modifiers).
        guard event.type == .keyDown || event.type == .keyUp else { return }
        guard UInt32(event.keyCode) == config.keyCode else { return }
        let present = Self.modifierSet(from: event)
        let modsOK = HotkeyMatcher.matches(required: HotkeyMatcher.decode(carbonMask: config.modifierFlags), present: present)

        switch event.type {
        case .keyDown where modsOK:
            if config.isPushToTalk {
                if !isChordDown { isChordDown = true; handler(.pressed) }   // ignores key auto-repeat
            } else if !event.isARepeat {
                handler(.toggled)
            }
        case .keyUp:
            if config.isPushToTalk && isChordDown { isChordDown = false; handler(.released) }
        default:
            break
        }
    }

    /// Map an NSEvent's modifiers into the platform-agnostic set, distinguishing
    /// LEFT Option via the physical key code (58) on a flags-changed event.
    static func modifierSet(from event: NSEvent) -> ModifierSet {
        let f = event.modifierFlags
        var set: ModifierSet = []
        if f.contains(.command)  { set.insert(.command) }
        if f.contains(.option)   { set.insert(.option) }
        if f.contains(.control)  { set.insert(.control) }
        if f.contains(.shift)    { set.insert(.shift) }
        if f.contains(.function) { set.insert(.function) }
        // Left Option via the underlying CGEvent device-flag bit
        // (NX_DEVICELALTKEYMASK = 0x20). This is set on ANY flags-changed event
        // while left ⌥ is held, so unrelated key presses don't spuriously end the
        // chord (which was splitting one dictation into several).
        if let cg = event.cgEvent, (cg.flags.rawValue & 0x20) != 0 { set.insert(.leftOption) }
        return set
    }
}
