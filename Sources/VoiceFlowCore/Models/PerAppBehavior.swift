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
    /// Per-app defaults.
    ///
    /// CONSISTENCY RULE (user decision 2026-08-08): dictation formats IDENTICALLY
    /// in every text box — full sentences, capitals, punctuation — chat, email,
    /// notes, code editors, terminals, all of it. No app silently gets a
    /// different result for the same speech. Code mode still exists as a MODE the
    /// user can assign to an app manually in Settings, but nothing defaults to it.
    /// (Email mode = the same full formatting + paragraph preservation.)
    static let defaults: [PerAppBehavior] = [
        PerAppBehavior(bundleIdentifier: "com.apple.mail", appName: "Mail", defaultMode: .email)
    ]
}
