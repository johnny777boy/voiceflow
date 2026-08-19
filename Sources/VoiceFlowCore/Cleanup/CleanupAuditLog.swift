import Foundation

/// The cleanup stage's own account of what it did with one dictation.
///
/// History used to store only the delivered text, and that made the recurring
/// complaint — "the cleanup is not accurate" — unanswerable. A dictation whose
/// polish the guard silently reverted is byte-identical to one the model had
/// nothing to fix: in both, `cleanText == rawText`. 21 of 28 real dictations
/// looked like that, and nobody could say which kind they were.
///
/// So the stage writes down what it PROPOSED and what was done with it, and the
/// controller copies that onto the history record. One slot, written by the
/// cleanup stage and taken by the controller for the dictation in flight —
/// dictations are serialised by the controller actor, so there is never more
/// than one in the slot.
public final class CleanupAuditLog: @unchecked Sendable {
    public struct Entry: Sendable, Equatable {
        /// What the model proposed, BEFORE the guard ruled on it.
        public var proposed: String?
        /// "accepted" · "partial" · "rejected" · "unavailable" · "timeout"
        /// · "fast-path" · "rules-only"
        public var decision: String
        /// Why the guard refused, when it did.
        public var reason: String?

        public init(proposed: String? = nil, decision: String, reason: String? = nil) {
            self.proposed = proposed
            self.decision = decision
            self.reason = reason
        }
    }

    private let lock = NSLock()
    private var entry: Entry?

    public init() {}

    /// The authoritative account, written by whoever actually saw the proposal.
    public func record(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        self.entry = entry
    }

    /// A coarser outcome, written only if nothing more precise was recorded.
    ///
    /// Ordering matters: the provider rejects a proposal and THROWS, and the
    /// pipeline catches that throw as "unavailable". Without this, the generic
    /// outer message would overwrite the precise inner one and the audit would
    /// lose the very reason it exists to capture.
    public func recordIfAbsent(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if self.entry == nil { self.entry = entry }
    }

    /// Read and clear, so one dictation's account can never be attributed to the
    /// next one.
    public func take() -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let taken = entry
        entry = nil
        return taken
    }
}
