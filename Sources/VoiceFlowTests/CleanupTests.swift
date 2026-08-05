import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

private func ctx(_ mode: DictationMode, _ strength: CleanupStrength = .standard) -> CleanupContext {
    CleanupContext(mode: mode, strength: strength, vocabulary: VocabularyEntry.defaults, languageCode: "en-US")
}

func runCleanupTests(_ s: TestSuite) {
    let engine = RuleBasedCleanup()

    s.test("Raw mode only normalizes whitespace and vocabulary") { s in
        let out = engine.cleanSync("i   use    postgres", context: ctx(.raw))
        s.expectEqual(out, "i use PostgreSQL")
    }

    s.test("Raw mode does not add punctuation or capitalize") { s in
        let out = engine.cleanSync("hello there", context: ctx(.raw))
        s.expectEqual(out, "hello there")
    }

    s.test("Clean writing capitalizes and adds terminal punctuation") { s in
        let out = engine.cleanSync("this is a test", context: ctx(.cleanWriting))
        s.expectEqual(out, "This is a test.")
    }

    s.test("Clean writing removes filler words") { s in
        let out = engine.cleanSync("um this is uh a test", context: ctx(.cleanWriting))
        s.expectEqual(out, "This is a test.")
    }

    s.test("Clean writing preserves meaningful words that look like fillers") { s in
        // "like", "actually", "kind of" carry meaning — must NOT be stripped.
        let out = engine.cleanSync("i actually like it kind of a lot", context: ctx(.cleanWriting))
        s.expect(out.lowercased().contains("like"), "kept 'like': \(out)")
        s.expect(out.lowercased().contains("actually"), "kept 'actually': \(out)")
        s.expect(out.lowercased().contains("kind of"), "kept 'kind of': \(out)")
    }

    s.test("Clean writing converts spoken punctuation") { s in
        let out = engine.cleanSync("hello there comma how are you question mark", context: ctx(.cleanWriting))
        s.expectEqual(out, "Hello there, how are you?")
    }

    s.test("Code mode preserves commands without trailing period") { s in
        let out = engine.cleanSync("git status", context: ctx(.claudeCode))
        s.expectEqual(out, "git status")
    }

    s.test("Code mode does not convert the word period to a symbol") { s in
        let out = engine.cleanSync("run npm run build period", context: ctx(.claudeCode))
        s.expect(out.contains("period"), "code mode kept 'period' literal, got: \(out)")
    }

    s.test("Code mode applies vocabulary") { s in
        let out = engine.cleanSync("open claude code and codex", context: ctx(.claudeCode))
        s.expectEqual(out, "open Claude Code and Codex")
    }

    s.test("Email mode preserves line breaks") { s in
        let out = engine.cleanSync("hi john\nthanks for the update", context: ctx(.email))
        s.expect(out.contains("\n"), "email preserved newline, got: \(out)")
    }

    s.test("Strength off disables transformations") { s in
        let out = engine.cleanSync("um this is a test", context: ctx(.cleanWriting, .off))
        s.expectEqual(out, "um this is a test")
    }

    s.test("Empty input yields empty output") { s in
        s.expectEqual(engine.cleanSync("   ", context: ctx(.cleanWriting)), "")
    }

    // Pipeline: LLM failure falls back to rule result.
    s.test("Pipeline falls back to rule result when LLM throws") { s in
        let pipeline = CleanupPipeline(llmProvider: FailingLLM(), useLLM: true)
        let result = blockingAwait { (try? await pipeline.clean("this is a test", context: ctx(.cleanWriting))) ?? "ERR" }
        s.expectEqual(result, "This is a test.")
    }

    s.test("Pipeline uses LLM output when it succeeds") { s in
        let pipeline = CleanupPipeline(llmProvider: FixedLLM(output: "REFINED"), useLLM: true)
        let result = blockingAwait { (try? await pipeline.clean("this is a test", context: ctx(.cleanWriting))) ?? "ERR" }
        s.expectEqual(result, "REFINED")
    }

    s.test("Pipeline skips LLM in raw mode") { s in
        let pipeline = CleanupPipeline(llmProvider: FixedLLM(output: "REFINED"), useLLM: true)
        let result = blockingAwait { (try? await pipeline.clean("hello postgres", context: ctx(.raw))) ?? "ERR" }
        s.expectEqual(result, "hello PostgreSQL")
    }

    s.test("Pipeline ignores empty LLM output and keeps rule result") { s in
        let pipeline = CleanupPipeline(llmProvider: FixedLLM(output: "   "), useLLM: true)
        let result = blockingAwait { (try? await pipeline.clean("this is a test", context: ctx(.cleanWriting))) ?? "ERR" }
        s.expectEqual(result, "This is a test.")
    }

    // MARK: - Phase-0 regression guards (word garbling / bad capitalization)

    s.test("Spoken-punctuation does not eat real words (command/colony/period)") { s in
        s.expectEqual(engine.cleanSync("run the command", context: ctx(.cleanWriting)), "Run the command.")
        s.expectEqual(engine.cleanSync("we visited the colony", context: ctx(.cleanWriting)), "We visited the colony.")
        s.expect(!engine.cleanSync("the periodic table", context: ctx(.cleanWriting)).contains(". table"),
                 "did not split 'periodic'")
    }

    s.test("Decimals are not treated as sentence ends") { s in
        s.expectEqual(engine.cleanSync("version 3.14 is ready", context: ctx(.cleanWriting)), "Version 3.14 is ready.")
    }

    s.test("Initialisms do not trigger mid-sentence capitalization") { s in
        s.expectEqual(engine.cleanSync("e.g. this is fine", context: ctx(.cleanWriting)), "E.g. this is fine.")
    }

    s.test("Meaningful phrases 'you know' / 'i mean' are preserved") { s in
        s.expect(engine.cleanSync("do you know the answer", context: ctx(.cleanWriting)).lowercased().contains("you know"),
                 "kept 'you know'")
        s.expect(engine.cleanSync("i mean it", context: ctx(.cleanWriting)).lowercased().contains("i mean"),
                 "kept 'i mean'")
    }

    s.test("Real spoken punctuation still converts") { s in
        s.expectEqual(engine.cleanSync("wait comma stop", context: ctx(.cleanWriting)), "Wait, stop.")
    }
}

private struct FailingLLM: CleanupProviding {
    func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        throw VoiceFlowError.cleanupProviderUnavailable
    }
}

private struct FixedLLM: CleanupProviding {
    let output: String
    func clean(_ rawText: String, context: CleanupContext) async throws -> String { output }
}
