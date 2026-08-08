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
    /// Convert spoken punctuation words ("period" → "."). OFF by default: the
    /// blind word→symbol mapping destroys those words used as ordinary nouns.
    public var spokenPunctuationEnabled: Bool
    /// Bias the recognizer with proper nouns read from the frontmost window via
    /// Accessibility (never screenshots, never uploaded). On by default: it is
    /// the accuracy lever that makes names/jargon transcribe correctly.
    public var screenContextEnabled: Bool
    /// Let short casual utterances skip the LLM cleanup pass (saves ~1s on the
    /// replies people send most often; questions and email always keep it).
    public var fastShortUtterances: Bool
    /// EXPERIMENTAL, off by default: insert the deterministic text instantly and
    /// upgrade it in place when the LLM polish lands. Needs live testing before
    /// it can be recommended — an in-place edit races the user's own typing.
    public var twoPhaseDeliveryEnabled: Bool

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
        useLLMCleanup: Bool = true,
        privacyRedactionEnabled: Bool = false,
        spokenPunctuationEnabled: Bool = false,
        screenContextEnabled: Bool = true,
        fastShortUtterances: Bool = true,
        twoPhaseDeliveryEnabled: Bool = false
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
        self.spokenPunctuationEnabled = spokenPunctuationEnabled
        self.screenContextEnabled = screenContextEnabled
        self.fastShortUtterances = fastShortUtterances
        self.twoPhaseDeliveryEnabled = twoPhaseDeliveryEnabled
    }

    /// Backward-compatible decoding: settings.json written by older builds lacks
    /// newer keys; a missing key must fall back to its default, never reset the
    /// whole settings file (SettingsStore returns `.default` on any throw).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID) ?? d.microphoneDeviceID
        hotkey = try c.decodeIfPresent(HotkeyConfiguration.self, forKey: .hotkey) ?? d.hotkey
        cleanupStrength = try c.decodeIfPresent(CleanupStrength.self, forKey: .cleanupStrength) ?? d.cleanupStrength
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode) ?? d.languageCode
        defaultMode = try c.decodeIfPresent(DictationMode.self, forKey: .defaultMode) ?? d.defaultMode
        vocabulary = try c.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? d.vocabulary
        perAppBehaviors = try c.decodeIfPresent([PerAppBehavior].self, forKey: .perAppBehaviors) ?? d.perAppBehaviors
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? d.historyEnabled
        historyRetentionLimit = try c.decodeIfPresent(Int.self, forKey: .historyRetentionLimit) ?? d.historyRetentionLimit
        overlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? d.overlayEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        useLLMCleanup = try c.decodeIfPresent(Bool.self, forKey: .useLLMCleanup) ?? d.useLLMCleanup
        privacyRedactionEnabled = try c.decodeIfPresent(Bool.self, forKey: .privacyRedactionEnabled) ?? d.privacyRedactionEnabled
        spokenPunctuationEnabled = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuationEnabled) ?? d.spokenPunctuationEnabled
        screenContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenContextEnabled) ?? d.screenContextEnabled
        fastShortUtterances = try c.decodeIfPresent(Bool.self, forKey: .fastShortUtterances) ?? d.fastShortUtterances
        twoPhaseDeliveryEnabled = try c.decodeIfPresent(Bool.self, forKey: .twoPhaseDeliveryEnabled) ?? d.twoPhaseDeliveryEnabled
    }

    public static let `default` = AppSettings()

    /// Resolve the effective mode for a destination. Priority: an explicit per-app
    /// rule the user set > automatic best-fit > the global default. Under the
    /// uniform-formatting policy the auto step yields Email for mail apps and
    /// Clean Writing for everything else — identical formatting everywhere;
    /// code mode happens only when the user explicitly assigns it to an app.
    public func mode(forBundleIdentifier bundleID: String?) -> DictationMode {
        if let bundleID,
           let rule = perAppBehaviors.first(where: { $0.bundleIdentifier == bundleID }) {
            return rule.defaultMode
        }
        if let bundleID, let auto = Self.autoMode(forBundleIdentifier: bundleID) {
            return auto
        }
        return defaultMode
    }

    /// Best-fit mode for a bundle id. CONSISTENCY RULE (user decision 2026-08-08):
    /// the same speech produces the same text in EVERY app — no destination
    /// silently downgrades formatting. Mail apps get Email mode (identical
    /// formatting, plus paragraph preservation); everything else — chat, notes,
    /// browsers, code editors, terminals — gets Clean Writing. Code mode is
    /// only ever reached via an explicit per-app rule the user sets.
    public static func autoMode(forBundleIdentifier bundleID: String) -> DictationMode? {
        let id = bundleID.lowercased()
        // EXACT bundle-id match only — a substring match ("mail") would
        // misclassify unrelated apps (com.example.mailroomInventory).
        let mailApps: Set<String> = [
            "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac",
            "com.airmailapp.airmail", "ru.keepcoder.telegram.mail", "com.sparkmailapp.spark"
        ]
        if mailApps.contains(id) { return .email }
        return .cleanWriting
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
