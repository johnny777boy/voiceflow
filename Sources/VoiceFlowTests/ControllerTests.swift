import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

private func makeController(
    transcript: String = "hello world",
    snapshot: DestinationSnapshot = MockActiveAppProvider.terminal(),
    capabilities: DestinationCapabilities = DestinationCapabilities(supportsAccessibilityInsertion: true, allowsSyntheticPaste: true, isSecureInput: false),
    settings: AppSettings = .default,
    activeApp: MockActiveAppProvider? = nil
) -> (DictationController, MockTextInserter, InMemoryHistoryStore, MockActiveAppProvider, MockTimeSource) {
    let audio = MockAudioRecorder()
    let transcriber = MockTranscriber(); transcriber.resultToReturn = TranscriptionResult(text: transcript)
    let inserter = MockTextInserter(); inserter.capabilities = capabilities
    let app = activeApp ?? MockActiveAppProvider(snapshot: snapshot)
    let history = InMemoryHistoryStore()
    let clock = MockTimeSource()
    let controller = DictationController(
        audio: audio, transcriber: transcriber, cleanup: CleanupPipeline(),
        inserter: inserter, activeApp: app, history: history, settings: settings, time: clock
    )
    return (controller, inserter, history, app, clock)
}

func runControllerTests(_ s: TestSuite) {
    s.test("Full pipeline inserts via accessibility and records history") { s in
        let (controller, inserter, history, _, clock) = makeController(transcript: "git status")
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            clock.advance(by: 1.5)
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        guard let result else { return }
        s.expectEqual(result.plan.strategy, .accessibility)
        s.expect(result.outcome.didInsert)
        s.expectEqual(inserter.insertedText, "git status")   // code mode keeps it literal
        s.expectEqual(try history.allRecords().count, 1)
        s.expect(result.record.latencySeconds >= 1.5)
    }

    s.test("Destination change diverts to clipboard, no insertion") { s in
        // App at record start is Terminal; at insert time it's Safari.
        let app = MockActiveAppProvider(snapshot: MockActiveAppProvider.terminal())
        let (controller, inserter, _, _, _) = makeController(activeApp: app)
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            app.snapshotToReturn = MockActiveAppProvider.safari()   // user switched apps
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        guard let result else { return }
        s.expectFalse(result.outcome.didInsert)
        s.expectEqual(result.plan.strategy, .copyOnly)
        s.expectNil(inserter.insertedText, "must not insert into the wrong app")
        s.expectNotNil(inserter.copiedText)
    }

    s.test("Secure field is never inserted into") { s in
        let (controller, inserter, _, _, _) = makeController(
            snapshot: MockActiveAppProvider.terminal(secure: true),
            capabilities: DestinationCapabilities(supportsAccessibilityInsertion: true, allowsSyntheticPaste: true, isSecureInput: true)
        )
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        s.expectFalse(result?.outcome.didInsert ?? true)
        s.expectNil(inserter.insertedText)
    }

    s.test("Email app resolves to email mode and cleaned prose") { s in
        let mailSnap = DestinationSnapshot(bundleIdentifier: "com.apple.mail", appName: "Mail", windowTitle: nil,
            focusedElementRole: "AXTextArea", focusedElementIdentifier: nil, isSecureInput: false,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0))
        let (controller, inserter, _, _, _) = makeController(transcript: "thanks for the update", snapshot: mailSnap)
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(result?.record.mode, .email)
        s.expectEqual(inserter.insertedText, "Thanks for the update.")
    }

    s.test("Empty transcript throws and records nothing") { s in
        let (controller, _, history, _, _) = makeController(transcript: "   ")
        let threw = blockingAwait { () -> Bool in
            try? await controller.beginRecording()
            do { _ = try await controller.finishRecording(); return false }
            catch { return true }
        }
        s.expect(threw)
        s.expectEqual((try? history.allRecords().count) ?? -1, 0)
    }

    s.test("finishRecording without beginRecording throws") { s in
        let (controller, _, _, _, _) = makeController()
        let threw = blockingAwait { () -> Bool in
            do { _ = try await controller.finishRecording(); return false }
            catch { return true }
        }
        s.expect(threw)
    }

    s.test("History disabled skips saving") { s in
        var settings = AppSettings.default
        settings.historyEnabled = false
        let (controller, _, history, _, _) = makeController(settings: settings)
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        s.expectEqual(try history.allRecords().count, 0)
    }
}
