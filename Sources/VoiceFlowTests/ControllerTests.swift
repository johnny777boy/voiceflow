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

/// A stand-in for the on-device model: proposes `proposal`, then reports to the
/// audit log exactly what the real provider reports.
private struct AuditingCleanup: CleanupProviding {
    let proposal: String
    let audit: CleanupAuditLog
    func prewarm() {}
    func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        let merged = CleanupGuard.safelyMerged(
            original: rawText, cleaned: proposal, policy: context.guardPolicy)
        if merged == proposal {
            audit.record(.init(proposed: proposal, decision: "accepted"))
            return merged
        }
        let reason = CleanupGuard.rejection(
            original: rawText, cleaned: proposal, policy: context.guardPolicy)?.description
        if merged == rawText {
            audit.record(.init(proposed: proposal, decision: "rejected", reason: reason))
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        audit.record(.init(proposed: proposal, decision: "partial", reason: reason))
        return merged
    }
}

func runControllerTests(_ s: TestSuite) {
    s.test("history records WHY the guard threw away the AI polish") { s in
        // The whole point: a reverted dictation must not look like a dictation
        // the model had nothing to fix. Both deliver rawText — only the audit
        // tells them apart.
        let audit = CleanupAuditLog()
        let audio = MockAudioRecorder()
        let transcriber = MockTranscriber()
        // Long enough to bypass the short-utterance fast path, or no model runs.
        transcriber.resultToReturn = TranscriptionResult(text: "we need to dig a new well behind the garage")
        let inserter = MockTextInserter()
        inserter.capabilities = DestinationCapabilities(
            supportsAccessibilityInsertion: true, allowsSyntheticPaste: true, isSecureInput: false)
        let history = InMemoryHistoryStore()
        let controller = DictationController(
            audio: audio, transcriber: transcriber,
            cleanup: CleanupPipeline(
                llmProvider: AuditingCleanup(
                    proposal: "We need to dig a new behind the garage.", audit: audit),
                useLLM: true),
            inserter: inserter, activeApp: MockActiveAppProvider(snapshot: MockActiveAppProvider.terminal()),
            history: history, settings: .default, time: MockTimeSource(), cleanupAudit: audit)
        _ = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            return try? await controller.finishRecording()
        }
        let saved = try history.allRecords().first
        s.expectEqual(saved?.cleanupDecision, "rejected")
        s.expectEqual(saved?.cleanupProposed, "We need to dig a new behind the garage.")
        s.expectEqual(saved?.cleanupRejectReason, "dropped the word \"well\"")
        // And the user still got his own words, unharmed.
        s.expect(saved?.cleanText.contains("well") == true, "got: \(saved?.cleanText ?? "nil")")
    }

    s.test("Full pipeline inserts via accessibility and records history") { s in
        // Code mode is now reached ONLY via an explicit user-set per-app rule
        // (uniform-formatting policy, 2026-08-08) — this test sets one so the
        // literal-tokens pipeline stays covered.
        var settings = AppSettings.default
        settings.perAppBehaviors.append(PerAppBehavior(
            bundleIdentifier: MockActiveAppProvider.terminal().bundleIdentifier ?? "com.apple.Terminal",
            appName: "Terminal", defaultMode: .claudeCode))
        let (controller, inserter, history, _, clock) = makeController(transcript: "git status", settings: settings)
        let result = blockingAwait { () -> DictationResult? in
            try? await controller.beginRecording()
            clock.advance(by: 1.5)
            return try? await controller.finishRecording()
        }
        s.expectNotNil(result)
        guard let result else { return }
        s.expectEqual(result.plan.strategy, .clipboardPaste)   // paste is the universal default
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
