import Foundation

/// User-configurable settings. Codable so it can be persisted as JSON in
/// Application Support and round-tripped in tests.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Preferred input device unique id (nil = system default).
    public var microphoneDeviceID: String?
    /// The global push-to-talk hotkey.
    public var hotkey: HotkeyConfiguration
    /// Default cleanup strength when an app has no override.
    public var cleanupStrength: CleanupStrength
    /// BCP-47 language code for transcription (e.g. `en-US`).
    public var languageCode: String
    /// The default mode when no per-app rule matches.
    public var defaultMode: DictationMode
    /// User + default vocabulary.
    public var vocabulary: [VocabularyEntry]
    /// Per-app overrides.
    public var perAppBehaviors: [PerAppBehavior]
    /// Whether history is retained at all.
    public var historyEnabled: Bool
    /// Max number of history records to keep (0 = unlimited).
    public var historyRetentionLimit: Int
    /// Whether the floating overlay is shown while recording.
    public var overlayEnabled: Bool
    /// Launch the app automatically at login.
    public var launchAtLogin: Bool
    /// Use the optional LLM cleanup stage when an API key is present.
    public var useLLMCleanup: Bool
    /// If true, never store raw audio and scrub transcripts marked private.
    public var privacyRedactionEnabled: Bool

    public init(
        microphoneDeviceID: String? = nil,
        hotkey: HotkeyConfiguration = .defaultPushToTalk,
        cleanupStrength: CleanupStrength = .standard,
        languageCode: String = "en-US",
        defaultMode: DictationMode = .cleanWriting,
        vocabulary: [VocabularyEntry] = VocabularyEntry.defaults,
        perAppBehaviors: [PerAppBehavior] = PerAppBehavior.defaults,
        historyEnabled: Bool = true,
        historyRetentionLimit: Int = 500,
        overlayEnabled: Bool = true,
        launchAtLogin: Bool = false,
        useLLMCleanup: Bool = false,
        privacyRedactionEnabled: Bool = false
    ) {
        self.microphoneDeviceID = microphoneDeviceID
        self.hotkey = hotkey
        self.cleanupStrength = cleanupStrength
        self.languageCode = languageCode
        self.defaultMode = defaultMode
        self.vocabulary = vocabulary
        self.perAppBehaviors = perAppBehaviors
        self.historyEnabled = historyEnabled
        self.historyRetentionLimit = historyRetentionLimit
        self.overlayEnabled = overlayEnabled
        self.launchAtLogin = launchAtLogin
        self.useLLMCleanup = useLLMCleanup
        self.privacyRedactionEnabled = privacyRedactionEnabled
    }

    public static let `default` = AppSettings()

    /// Resolve the effective mode for a destination, honoring per-app overrides.
    public func mode(forBundleIdentifier bundleID: String?) -> DictationMode {
        if let bundleID,
           let rule = perAppBehaviors.first(where: { $0.bundleIdentifier == bundleID }) {
            return rule.defaultMode
        }
        return defaultMode
    }

    /// Whether the destination app is configured to force copy-only insertion.
    public func forcesCopyOnly(forBundleIdentifier bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return perAppBehaviors.first(where: { $0.bundleIdentifier == bundleID })?.forceCopyOnly ?? false
    }
}

/// A global hotkey definition: a key plus modifier flags (Carbon-compatible).
public struct HotkeyConfiguration: Codable, Sendable, Equatable, Hashable {
    /// Virtual keycode (kVK_*). Optional so a pure-modifier chord can be expressed.
    public var keyCode: UInt32?
    /// Carbon-style modifier mask (cmd/opt/ctrl/shift/fn).
    public var modifierFlags: UInt32
    /// Human-readable description for display (e.g. "⌥Space").
    public var displayString: String
    /// When true, the hotkey is push-to-talk (hold to record). When false, toggle.
    public var isPushToTalk: Bool

    public init(keyCode: UInt32?, modifierFlags: UInt32, displayString: String, isPushToTalk: Bool = true) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.displayString = displayString
        self.isPushToTalk = isPushToTalk
    }

    /// Default: hold the LEFT Option (⌥) key alone to talk — a single key that
    /// doesn't type. `keyCode == nil` marks a pure-modifier trigger driven by flag
    /// changes; the LEFT-specific sentinel keeps the right ⌥ free for typing.
    public static let defaultPushToTalk = HotkeyConfiguration(
        keyCode: nil,
        modifierFlags: HotkeyMatcher.carbonLeftOption,
        displayString: "⌥ Left Option",
        isPushToTalk: true
    )
}
