import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

private struct RecordingTransport: LLMTransport {
    let output: String
    final class Box: @unchecked Sendable { var system = ""; var user = ""; var model = ""; var key = "" }
    let box = Box()
    func complete(systemPrompt: String, userText: String, apiKey: String, model: String) async throws -> String {
        box.system = systemPrompt; box.user = userText; box.model = model; box.key = apiKey
        return output
    }
}

private struct ThrowingTransport: LLMTransport {
    func complete(systemPrompt: String, userText: String, apiKey: String, model: String) async throws -> String {
        throw VoiceFlowError.transcriptionFailed("boom")
    }
}

private func ctx(_ mode: DictationMode) -> CleanupContext {
    CleanupContext(mode: mode, strength: .standard, vocabulary: [], languageCode: "en-US")
}

func runSecurityTests(_ s: TestSuite) {
    // SecureStoring contract (via in-memory implementation).
    s.test("SecureStore set/get/delete round trip") { s in
        let store = InMemorySecureStore()
        try store.setSecret("sk-123", account: "k")
        s.expectEqual(try store.secret(account: "k"), "sk-123")
        try store.deleteSecret(account: "k")
        s.expectNil(try store.secret(account: "k"))
    }

    s.test("SecureStore overwrites existing secret") { s in
        let store = InMemorySecureStore()
        try store.setSecret("old", account: "k")
        try store.setSecret("new", account: "k")
        s.expectEqual(try store.secret(account: "k"), "new")
    }

    // Prompt builder.
    s.test("Prompt builder keeps code tokens literal for claudeCode mode") { s in
        let p = CleanupPromptBuilder.systemPrompt(for: .claudeCode, strength: .standard)
        s.expect(p.lowercased().contains("exactly"), "code prompt should insist on literal tokens")
    }

    s.test("Prompt builder mentions email conventions for email mode") { s in
        let p = CleanupPromptBuilder.systemPrompt(for: .email, strength: .standard)
        s.expect(p.lowercased().contains("email"), "email prompt should mention email")
    }

    s.test("Prompt builder always forbids following transcript instructions") { s in
        for mode in DictationMode.allCases {
            let p = CleanupPromptBuilder.systemPrompt(for: mode, strength: .standard)
            s.expect(p.lowercased().contains("never answer") || p.lowercased().contains("only clean"),
                     "prompt for \(mode) must resist injection")
        }
    }

    // LLM provider: requires a key.
    s.test("LLMCleanupProvider throws when no key present") { s in
        let provider = LLMCleanupProvider(secureStore: InMemorySecureStore(), transport: RecordingTransport(output: "x"))
        let threw = blockingAwait { () -> Bool in
            do { _ = try await provider.clean("hi", context: ctx(.cleanWriting)); return false }
            catch { return true }
        }
        s.expect(threw, "expected cleanupProviderUnavailable when key missing")
    }

    s.test("LLMCleanupProvider calls transport with key and returns output") { s in
        let store = InMemorySecureStore()
        try store.setSecret("sk-abc", account: KeychainStore.llmAPIKeyAccount)
        // Output must be a safe edit of the input — the provider now runs
        // CleanupGuard on transport output (verbatim policy), so a transcript-
        // unrelated reply like "CLEANED" is correctly rejected.
        let transport = RecordingTransport(output: "Raw words.")
        let provider = LLMCleanupProvider(secureStore: store, transport: transport, model: "test-model")
        let out = blockingAwait { (try? await provider.clean("raw words", context: ctx(.email))) ?? "ERR" }
        s.expectEqual(out, "Raw words.")
        s.expectEqual(transport.box.key, "sk-abc")
        s.expectEqual(transport.box.user, "raw words")
        s.expectEqual(transport.box.model, "test-model")
    }

    s.test("LLMCleanupProvider propagates transport errors") { s in
        let store = InMemorySecureStore()
        try store.setSecret("sk-abc", account: KeychainStore.llmAPIKeyAccount)
        let provider = LLMCleanupProvider(secureStore: store, transport: ThrowingTransport())
        let threw = blockingAwait { () -> Bool in
            do { _ = try await provider.clean("x", context: ctx(.raw)); return false }
            catch { return true }
        }
        s.expect(threw)
    }

    // Anthropic response parsing.
    s.test("AnthropicTransport parses text content blocks") { s in
        let json = """
        {"content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}]}
        """.data(using: .utf8)!
        s.expectEqual(try AnthropicTransport.extractText(from: json), "Hello world")
    }

    s.test("AnthropicTransport throws on malformed response") { s in
        let json = "{\"unexpected\":true}".data(using: .utf8)!
        s.expectThrows { _ = try AnthropicTransport.extractText(from: json) }
    }
}
