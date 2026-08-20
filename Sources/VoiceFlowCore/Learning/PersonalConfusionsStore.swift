import Foundation

/// Persists the confusions mined from his re-dictations. On-device JSON, like
/// every other store here. Write-side of the loop: `RedictationDetector` feeds
/// it; nothing reads it for APPLICATION yet — that wiring waits for the strict
/// guard set agreed in the Codex round-2 verdict. Until then it accumulates
/// evidence, which is exactly what the application guards will need anyway
/// (sighting counts).
public final class PersonalConfusionsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var rules: [PersonalConfusions.Rule]

    public init(url: URL) {
        self.url = url
        self.rules = (try? JSONDecoder().decode(
            [PersonalConfusions.Rule].self, from: Data(contentsOf: url))) ?? []
    }

    public func allRules() -> [PersonalConfusions.Rule] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    public func record(heard: String, said: String) {
        lock.lock(); defer { lock.unlock() }
        rules = PersonalConfusions.learning(rules, heard: heard, said: said)
        if let data = try? JSONEncoder().encode(rules) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
}
