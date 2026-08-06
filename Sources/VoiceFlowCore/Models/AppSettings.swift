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
        useLLMCleanup: Bool = true,
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

    /// Resolve the effective mode for a destination. Priority: an explicit per-app
    /// rule the user set > automatic best-fit for the app > the global default.
    /// The auto step means the right mode is chosen everywhere without the user
    /// managing it: code/terminal apps keep tokens literal, mail keeps paragraphs,
    /// and everything else gets polished Clean Writing.
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

    /// Best-fit mode for a bundle id, or nil if we have no strong opinion (caller
    /// falls back to the global default). Code editors/terminals → code mode; mail
    /// apps → email; common prose apps (chat, browsers, notes, docs) → Clean Writing.
    public static func autoMode(forBundleIdentifier bundleID: String) -> DictationMode? {
        let id = bundleID.lowercased()
        let codeApps: Set<String> = [
            "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.visualstudio.code.oss",
            "com.todesktop.230313mzl4w4u92",           // Cursor
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
            "com.apple.dt.xcode", "com.jetbrains.intellij", "com.sublimetext.4", "com.github.atom"
        ]
        if codeApps.contains(id) || id.contains("iterm") || id.contains("terminal")
            || id.hasSuffix(".vscode") { return .claudeCode }
        let mailApps: Set<String> = [
            "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.airmailapp.airmail"
        ]
        if mailApps.contains(id) || id.contains("mail") || id.contains("outlook") { return .email }
        // Chat / browsers / notes / docs — prose destinations → polished writing.
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
