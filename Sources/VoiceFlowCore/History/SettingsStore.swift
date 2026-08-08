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
    public static func migrate(_ settings: AppSettings) -> AppSettings {
        let legacySeededBundleIDs: Set<String> = [
            "com.anthropic.claudefordesktop", "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode", "com.apple.Terminal", "com.googlecode.iterm2",
            "com.tinyspeck.slackmacgap", "com.apple.Safari", "com.google.Chrome",
            "com.apple.Notes",
        ]
        var migrated = settings
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
