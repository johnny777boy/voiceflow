import Foundation

/// Abstraction over secret storage (Keychain in production). Used for the
/// optional LLM cleanup API key.
public protocol SecureStoring: AnyObject, Sendable {
    /// Store a secret under `account`. Overwrites any existing value.
    func setSecret(_ value: String, account: String) throws
    /// Retrieve a secret, or nil if absent.
    func secret(account: String) throws -> String?
    /// Delete a secret. No-op if absent.
    func deleteSecret(account: String) throws
}

public extension SecureStoring {
    /// Well-known account name for the optional cleanup LLM API key.
    static var llmAPIKeyAccount: String { "llm-cleanup-api-key" }
}
