import Foundation
import AppKit
import Carbon.HIToolbox
import VoiceFlowCore

/// System-wide push-to-talk / toggle hotkey via a CGEvent tap. Requires
/// Accessibility permission to observe key events globally.
final class GlobalHotkeyManager: HotkeyManaging, @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var configuration: HotkeyConfiguration?
    private var handler: (@Sendable (HotkeyEvent) -> Void)?
    private var isChordDown = false

    /// Whether a live event tap currently exists (i.e. registration succeeded).
    var isActive: Bool { eventTap != nil }

    func register(_ configuration: HotkeyConfiguration, handler: @escaping @Sendable (HotkeyEvent) -> Void) {
        unregister()
        self.configuration = configuration
        self.handler = handler

        // Include flagsChanged so a modifier release (while the main key is still
        // held) can end a push-to-talk chord.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // active tap so we can CONSUME the hotkey key
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                var consume = false
                if let refcon {
                    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    consume = manager.handle(type: type, event: event)
                }
                // Returning nil discards the event (so the push-to-talk key does
                // not type a character); otherwise pass it through unchanged.
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("Failed to create event tap (missing Accessibility permission?)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("Registered hotkey \(configuration.displayString, privacy: .public)")
    }

    func unregister() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        configuration = nil
        handler = nil
        isChordDown = false
    }

    // MARK: - Event handling

    /// Handle a tapped event. Returns `true` if the event should be **consumed**
    /// (swallowed) so the hotkey key doesn't type a character.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables an active tap if the callback is ever too slow;
        // re-enable it so the hotkey keeps working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        guard let config = configuration, let handler else { return false }

        let present = Self.modifierSet(from: event.flags)
        let modsOK = HotkeyMatcher.matches(
            required: HotkeyMatcher.decode(carbonMask: config.modifierFlags), present: present)

        // A modifier changed (no key up/down). Only used to END a held
        // push-to-talk chord. Never consumed — modifier keys must keep working.
        if type == .flagsChanged {
            if HotkeyMatcher.shouldEndChord(isChordDown: isChordDown,
                                            isPushToTalk: config.isPushToTalk,
                                            modifiersStillMatch: modsOK) {
                isChordDown = false
                handler(.released)
            }
            return false
        }

        // keyDown / keyUp: gate on the configured key code.
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard config.keyCode == nil || config.keyCode == keyCode else { return false }

        guard modsOK else {
            // Chord broken (modifier released together with a key event).
            if type == .keyUp,
               HotkeyMatcher.shouldEndChord(isChordDown: isChordDown,
                                            isPushToTalk: config.isPushToTalk,
                                            modifiersStillMatch: false) {
                isChordDown = false
                handler(.released)
                return true   // consume the matching key-up that ended the chord
            }
            return false
        }

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if config.isPushToTalk {
                if !isChordDown { isChordDown = true; handler(.pressed) }   // ignores auto-repeat via isChordDown
            } else if !isRepeat {
                handler(.toggled)   // one toggle per physical press, not per auto-repeat
            }
            return true   // consume the hotkey key-down (and its auto-repeats)
        case .keyUp:
            if config.isPushToTalk && isChordDown {
                isChordDown = false
                handler(.released)
            }
            return true   // consume the matching key-up
        default:
            return false
        }
    }

    /// Map live CGEvent modifier flags into the platform-agnostic `ModifierSet`.
    private static func modifierSet(from flags: CGEventFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        return set
    }
}
