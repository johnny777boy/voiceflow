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
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.history.error("Failed to decode settings, using defaults: \(String(describing: error), privacy: .public)")
            return .default
        }
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
