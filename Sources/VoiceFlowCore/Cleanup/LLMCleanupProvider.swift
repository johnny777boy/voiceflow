import Foundation

/// Abstraction over the HTTP call to an LLM, so `LLMCleanupProvider` is testable
/// without a network and remains provider-agnostic.
public protocol LLMTransport: Sendable {
    /// Send a single-shot completion request and return the model's text.
    func complete(systemPrompt: String, userText: String, apiKey: String, model: String) async throws -> String
}

/// Optional AI cleanup stage backed by an LLM. Reads the API key from secure
/// storage; if no key is present it throws `cleanupProviderUnavailable`, which the
/// `CleanupPipeline` treats as a signal to fall back to the rule-based result.
/// This is why a missing secret never blocks dictation.
public struct LLMCleanupProvider: CleanupProviding {
    private let secureStore: SecureStoring
    private let transport: LLMTransport
    private let model: String
    private let account: String

    public init(
        secureStore: SecureStoring,
        transport: LLMTransport = AnthropicTransport(),
        model: String = VoiceFlowInfo.defaultCleanupModel,
        account: String = KeychainStore.llmAPIKeyAccount
    ) {
        self.secureStore = secureStore
        self.transport = transport
        self.model = model
        self.account = account
    }

    public func clean(_ rawText: String, context: CleanupContext) async throws -> String {
        guard let key = try secureStore.secret(account: account), !key.isEmpty else {
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        let system = CleanupPromptBuilder.systemPrompt(for: context.mode, strength: context.strength)
        let raw = try await transport.complete(systemPrompt: system, userText: rawText, apiKey: key, model: model)
        // Same output hygiene as the on-device provider: strip any leaked
        // "Here is the cleaned text:" preamble, and reject meaning-changing
        // rewrites so the pipeline falls back to the rule-based result.
        let text = TextNormalizer.stripLLMPreamble(raw)
        guard CleanupGuard.preservesMeaning(original: rawText, cleaned: text) else {
            throw VoiceFlowError.cleanupProviderUnavailable
        }
        return text
    }
}

/// Default transport: Anthropic Messages API over URLSession.
public struct AnthropicTransport: LLMTransport {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession
    private let maxTokens: Int

    public init(session: URLSession = .shared, maxTokens: Int = 1024) {
        self.session = session
        self.maxTokens = maxTokens
    }

    public func complete(systemPrompt: String, userText: String, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userText]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceFlowError.transcriptionFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw VoiceFlowError.transcriptionFailed("LLM HTTP \(http.statusCode): \(message)")
        }
        return try Self.extractText(from: data)
    }

    /// Parse the Anthropic Messages response, concatenating text content blocks.
    public static func extractText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw VoiceFlowError.transcriptionFailed("unexpected LLM response shape")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text
    }
}
