import Foundation

/// A platform-agnostic set of modifier keys, so hotkey matching can be unit-tested
/// without CoreGraphics / Carbon types.
public struct ModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command  = ModifierSet(rawValue: 1 << 0)
    public static let option   = ModifierSet(rawValue: 1 << 1)
    public static let control  = ModifierSet(rawValue: 1 << 2)
    public static let shift    = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)   // the fn / Globe key
}

/// Pure hotkey-matching logic shared between the production event tap and tests.
///
/// The production layer decodes a live keyboard event's modifier flags into a
/// `ModifierSet` and calls `matches` with the required modifiers derived from the
/// configured Carbon mask. Keeping the decision here (rather than inline in the
/// CGEvent callback) makes the tricky boundary cases testable.
public enum HotkeyMatcher {
    // Carbon modifier masks (from <Carbon/Events.h>).
    public static let carbonCommand: UInt32 = 0x0100
    public static let carbonShift: UInt32   = 0x0200
    public static let carbonOption: UInt32  = 0x0800
    public static let carbonControl: UInt32 = 0x1000
    /// Custom sentinel (outside the Carbon range) for the fn / Globe key.
    public static let carbonFunction: UInt32 = 0x0080_0000

    /// Convert a Carbon-style modifier mask into a `ModifierSet`.
    public static func decode(carbonMask: UInt32) -> ModifierSet {
        var set: ModifierSet = []
        if carbonMask & carbonCommand  != 0 { set.insert(.command) }
        if carbonMask & carbonShift    != 0 { set.insert(.shift) }
        if carbonMask & carbonOption   != 0 { set.insert(.option) }
        if carbonMask & carbonControl  != 0 { set.insert(.control) }
        if carbonMask & carbonFunction != 0 { set.insert(.function) }
        return set
    }

    /// Whether the currently-pressed modifiers satisfy the required chord.
    ///
    /// Every required modifier must be present. Extra modifiers being held do NOT
    /// break the match — this mirrors typical hotkey behavior (e.g. ⌥Space still
    /// fires if Shift is also incidentally down), while still requiring all of the
    /// configured modifiers.
    public static func matches(required: ModifierSet, present: ModifierSet) -> Bool {
        present.isSuperset(of: required)
    }

    /// For push-to-talk: whether a change (a modifier released, or the key going
    /// up) should end the currently-held chord and emit `.released`. Extracted so
    /// the "modifier released while the main key is still down" case — which the
    /// live event tap must handle via `flagsChanged` — is unit-tested.
    public static func shouldEndChord(isChordDown: Bool, isPushToTalk: Bool, modifiersStillMatch: Bool) -> Bool {
        isChordDown && isPushToTalk && !modifiersStillMatch
    }

    /// Whether a key event with `keyCode` and `present` modifiers triggers the
    /// configured hotkey. A `nil` configured keyCode matches any key (pure-modifier
    /// chord).
    public static func triggers(
        configuredKeyCode: UInt32?,
        configuredCarbonMask: UInt32,
        eventKeyCode: UInt32,
        present: ModifierSet
    ) -> Bool {
        if let configuredKeyCode, configuredKeyCode != eventKeyCode { return false }
        return matches(required: decode(carbonMask: configuredCarbonMask), present: present)
    }
}
