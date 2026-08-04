import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

private func makeRecord(_ clean: String, at t: TimeInterval) -> TranscriptRecord {
    TranscriptRecord(rawText: clean.lowercased(), cleanText: clean, appBundleIdentifier: "com.apple.Terminal",
        appName: "Terminal", mode: .claudeCode, insertionStrategy: .accessibility, latencySeconds: 0.5,
        createdAt: Date(timeIntervalSince1970: t))
}

private func exerciseStore(_ s: TestSuite, _ label: String, _ makeStore: () throws -> HistoryStoring) {
    s.test("\(label): save and fetch all newest-first") { s in
        let store = try makeStore()
        try store.save(makeRecord("first", at: 100))
        try store.save(makeRecord("second", at: 200))
        let all = try store.allRecords()
        s.expectEqual(all.count, 2)
        s.expectEqual(all.first?.cleanText, "second")
    }

    s.test("\(label): fetch by id and delete") { s in
        let store = try makeStore()
        let r = makeRecord("one", at: 100)
        try store.save(r)
        s.expectEqual(try store.record(id: r.id)?.cleanText, "one")
        try store.delete(id: r.id)
        s.expectNil(try store.record(id: r.id))
    }

    s.test("\(label): update via save with same id") { s in
        let store = try makeStore()
        var r = makeRecord("draft", at: 100)
        try store.save(r)
        r.cleanText = "final"
        try store.save(r)
        s.expectEqual(try store.allRecords().count, 1)
        s.expectEqual(try store.record(id: r.id)?.cleanText, "final")
    }

    s.test("\(label): deleteAll clears store") { s in
        let store = try makeStore()
        try store.save(makeRecord("a", at: 1))
        try store.save(makeRecord("b", at: 2))
        try store.deleteAll()
        s.expectEqual(try store.allRecords().count, 0)
    }

    s.test("\(label): trim keeps only newest N") { s in
        let store = try makeStore()
        for i in 1...5 { try store.save(makeRecord("r\(i)", at: TimeInterval(i))) }
        try store.trim(toMostRecent: 2)
        let all = try store.allRecords()
        s.expectEqual(all.count, 2)
        s.expectEqual(all.map { $0.cleanText }, ["r5", "r4"])
    }

    s.test("\(label): all fields survive round trip") { s in
        let store = try makeStore()
        let r = TranscriptRecord(rawText: "raw text", cleanText: "Clean text.", appBundleIdentifier: "com.x",
            appName: "X", mode: .email, insertionStrategy: .clipboardPaste, latencySeconds: 1.25,
            errorMessage: "degraded", createdAt: Date(timeIntervalSince1970: 500))
        try store.save(r)
        s.expectEqual(try store.record(id: r.id), r)
    }
}

func runHistoryStoreTests(_ s: TestSuite) {
    exerciseStore(s, "InMemory") { InMemoryHistoryStore() }

    exerciseStore(s, "SQLite") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-tests-\(UUID().uuidString)", isDirectory: true)
        return try SQLiteHistoryStore(url: dir.appendingPathComponent("history.sqlite"))
    }

    s.test("SQLite persists across reopen") { s in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-persist-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("history.sqlite")
        let r = makeRecord("persisted", at: 42)
        do { let store = try SQLiteHistoryStore(url: url); try store.save(r) }
        let reopened = try SQLiteHistoryStore(url: url)
        s.expectEqual(try reopened.record(id: r.id)?.cleanText, "persisted")
    }

    s.test("SettingsStore round-trips to disk") { s in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-settings-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var settings = AppSettings.default
        settings.languageCode = "en-GB"
        settings.overlayEnabled = false
        try store.save(settings)
        let loaded = SettingsStore(url: url).load()
        s.expectEqual(loaded.languageCode, "en-GB")
        s.expectFalse(loaded.overlayEnabled)
    }

    s.test("SettingsStore returns defaults for missing file") { s in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceflow-missing-\(UUID().uuidString)")
            .appendingPathComponent("nope.json")
        s.expectEqual(SettingsStore(url: url).load(), AppSettings.default)
    }
}
