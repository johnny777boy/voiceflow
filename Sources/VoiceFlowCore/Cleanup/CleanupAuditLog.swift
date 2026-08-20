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
        /// Which dictation this account belongs to. Without it, an abandoned
        /// timeout task (`withDeadline` races the model and ABANDONS the loser,
        /// which keeps running) or two-phase delivery's second cleanup can drop
        /// its entry into the slot while the NEXT dictation is in flight — so
        /// N+1's history row stores N's proposed text and N's verdict.
        public var dictationID: UUID?
        /// What the model proposed, BEFORE the guard ruled on it.
        public var proposed: String?
        /// "accepted" · "partial" · "rejected" · "unavailable" · "timeout"
        /// · "fast-path" · "rules-only"
        public var decision: String
        /// Why the guard refused, when it did.
        public var reason: String?

        public init(dictationID: UUID? = nil, proposed: String? = nil,
                    decision: String, reason: String? = nil) {
            self.dictationID = dictationID
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
    /// next one. An entry stamped for a DIFFERENT dictation is discarded rather
    /// than returned — a late writer from a previous dictation must not be
    /// mistaken for this one's account.
    public func take(expecting id: UUID? = nil) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        let taken = entry
        entry = nil
        if let id, let taken, let stamped = taken.dictationID, stamped != id { return nil }
        return taken
    }
}
