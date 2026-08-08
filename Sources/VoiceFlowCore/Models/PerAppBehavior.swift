import Foundation

/// Per-application overrides for how dictation should behave when a given app is
/// the destination.
public struct PerAppBehavior: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { bundleIdentifier }
    /// Bundle identifier this rule applies to.
    public var bundleIdentifier: String
    /// Friendly name for display.
    public var appName: String
    /// The mode to use by default for this app.
    public var defaultMode: DictationMode
    /// If true, prefer copy-only insertion for this app regardless of capability.
    public var forceCopyOnly: Bool

    public init(
        bundleIdentifier: String,
        appName: String,
        defaultMode: DictationMode,
        forceCopyOnly: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.defaultMode = defaultMode
        self.forceCopyOnly = forceCopyOnly
    }
}

public extension PerAppBehavior {
    /// Sensible per-app defaults mapping the spec's primary targets to modes.
    ///
    /// CONSISTENCY RULE (user decision 2026-08-08): dictation formats the same
    /// everywhere — full sentences, capitals, punctuation. Code mode is reserved
    /// for surfaces where formatting literally breaks input (terminals, code
    /// editors). Chat apps — including AI chat like Claude — are prose.
    static let defaults: [PerAppBehavior] = [
        // AI chat → prose, same as any messenger.
        PerAppBehavior(bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude", defaultMode: .cleanWriting),
        // True code surfaces → Claude Code mode (a capital or trailing period
        // corrupts commands/identifiers there).
        PerAppBehavior(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor", defaultMode: .claudeCode),
        PerAppBehavior(bundleIdentifier: "com.microsoft.VSCode", appName: "VS Code", defaultMode: .claudeCode),
        PerAppBehavior(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", defaultMode: .claudeCode),
        PerAppBehavior(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2", defaultMode: .claudeCode),
        // Mail & messaging → Email / Clean.
        PerAppBehavior(bundleIdentifier: "com.apple.mail", appName: "Mail", defaultMode: .email),
        PerAppBehavior(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack", defaultMode: .cleanWriting),
        // Browsers & notes → Clean writing.
        PerAppBehavior(bundleIdentifier: "com.apple.Safari", appName: "Safari", defaultMode: .cleanWriting),
        PerAppBehavior(bundleIdentifier: "com.google.Chrome", appName: "Chrome", defaultMode: .cleanWriting),
        PerAppBehavior(bundleIdentifier: "com.apple.Notes", appName: "Notes", defaultMode: .cleanWriting)
    ]
}
