import Foundation

/// Loads and persists `AppSettings` as JSON. Missing/corrupt files fall back to
/// defaults so the app always starts.
public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = AppPaths.settingsURL()) {
        self.url = url
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return .default }
        do {
            return Self.migrate(try JSONDecoder().decode(AppSettings.self, from: data))
        } catch {
            Log.history.error("Failed to decode settings, using defaults: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    /// One-time cleanups of rows SEEDED by older builds (never of user-created
    /// rules). Uniform-formatting migration (2026-08-08): old builds seeded
    /// per-app code-mode rows (Claude, VS Code, Terminal, iTerm2, Cursor) plus
    /// redundant cleanWriting rows; stored rules outrank autoMode, so without
    /// this, existing installs silently keep the pre-uniform behavior. A row is
    /// removed only if it exactly matches a known legacy seed (same bundle id,
    /// seeded mode or its hand-flipped cleanWriting variant, no copy-only flag) —
    /// anything the user customized survives.
    /// Marks the one-time fast-path migration as applied.
    static let fastPathMigrationKey = "migratedFastPathOff2026_08_18"

    public static func migrate(_ settings: AppSettings) -> AppSettings {
        let legacySeededBundleIDs: Set<String> = [
            "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
            "com.tinyspeck.slackmacgap", "com.apple.Safari", "com.google.Chrome",
            "com.apple.Notes",
        ]
        var migrated = settings
        // One-time (2026-08-18): force the short-utterance fast path OFF.
        // Changing its DEFAULT was not enough — AppSettings encodes every key, so
        // any existing settings.json already carries `fastShortUtterances: true`
        // and `decodeIfPresent` keeps it. The install that reported the accuracy
        // bug would therefore have kept skipping the repair pass on exactly the
        // short dictations that needed it. The marker means a user who
        // deliberately re-enables it is never overridden again.
        if !UserDefaults.standard.bool(forKey: fastPathMigrationKey) {
            migrated.fastShortUtterances = false
            UserDefaults.standard.set(true, forKey: fastPathMigrationKey)
        }
        migrated.perAppBehaviors.removeAll { rule in
            legacySeededBundleIDs.contains(rule.bundleIdentifier)
                && (rule.defaultMode == .claudeCode || rule.defaultMode == .cleanWriting)
                && !rule.forceCopyOnly
        }
        return migrated
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
