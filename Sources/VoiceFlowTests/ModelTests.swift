import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

func runModelTests(_ s: TestSuite) {
    s.test("DestinationSnapshot matches same app") { s in
        s.expect(MockActiveAppProvider.terminal().matches(MockActiveAppProvider.terminal()))
    }

    s.test("DestinationSnapshot rejects different app") { s in
        s.expectFalse(MockActiveAppProvider.terminal().matches(MockActiveAppProvider.safari()))
    }

    s.test("DestinationSnapshot rejects mismatched focused element identifier") { s in
        let a = DestinationSnapshot(bundleIdentifier: "com.x", appName: "X", windowTitle: nil,
            focusedElementRole: "AXTextArea", focusedElementIdentifier: "field-1",
            isSecureInput: false, capturedAt: .init(timeIntervalSinceReferenceDate: 0))
        let b = DestinationSnapshot(bundleIdentifier: "com.x", appName: "X", windowTitle: nil,
            focusedElementRole: "AXTextArea", focusedElementIdentifier: "field-2",
            isSecureInput: false, capturedAt: .init(timeIntervalSinceReferenceDate: 0))
        s.expectFalse(a.matches(b))
    }

    s.test("Settings resolves per-app mode") { s in
        let settings = AppSettings.default
        s.expectEqual(settings.mode(forBundleIdentifier: "com.apple.mail"), .email)
        s.expectEqual(settings.mode(forBundleIdentifier: "com.apple.Terminal"), .claudeCode)
        s.expectEqual(settings.mode(forBundleIdentifier: "com.unknown.app"), .cleanWriting)
    }

    s.test("Settings round-trips through JSON") { s in
        let settings = AppSettings.default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        s.expectEqual(settings, decoded)
    }

    s.test("TranscriptRecord round-trips through JSON") { s in
        let record = TranscriptRecord(rawText: "raw", cleanText: "Clean.", appBundleIdentifier: "com.apple.Terminal",
            appName: "Terminal", mode: .claudeCode, insertionStrategy: .accessibility, latencySeconds: 1.2)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TranscriptRecord.self, from: data)
        s.expectEqual(record, decoded)
    }

    s.test("Default vocabulary and per-app behaviors are non-empty") { s in
        s.expectFalse(VocabularyEntry.defaults.isEmpty)
        s.expectFalse(PerAppBehavior.defaults.isEmpty)
    }
}
