import Foundation

/// Resolves on-disk locations under Application Support for the app's data.
public enum AppPaths {
    /// Base directory: ~/Library/Application Support/VoiceFlow
    public static func baseDirectory(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VoiceFlow", isDirectory: true)
    }

    public static func historyDatabaseURL(fileManager: FileManager = .default) -> URL {
        baseDirectory(fileManager: fileManager).appendingPathComponent("history.sqlite")
    }

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        baseDirectory(fileManager: fileManager).appendingPathComponent("settings.json")
    }

    /// Corrections observed after insertion, awaiting the user's accept/dismiss.
    public static func suggestedVocabularyURL(fileManager: FileManager = .default) -> URL {
        baseDirectory(fileManager: fileManager).appendingPathComponent("suggested-vocabulary.json")
    }
}
