import Foundation

/// The concrete plan for delivering text, produced after re-verifying the
/// destination immediately before insertion.
public struct InsertionPlan: Equatable, Sendable {
    /// The strategy to use.
    public let strategy: InsertionStrategy
    /// Whether the destination matched the one captured at recording start.
    public let destinationVerified: Bool
    /// Whether text will actually be delivered (false ⇒ copy-only / preview).
    public let willInsert: Bool
    /// Human-readable explanation, surfaced in the overlay/history when degraded.
    public let note: String?

    public init(strategy: InsertionStrategy, destinationVerified: Bool, willInsert: Bool, note: String?) {
        self.strategy = strategy
        self.destinationVerified = destinationVerified
        self.willInsert = willInsert
        self.note = note
    }
}

/// Destination protection: compares the snapshot captured at recording start with
/// the live destination just before insertion and decides whether it is safe to
/// insert. It never returns an inserting plan when the destination changed or the
/// field is secure — in those cases text is copied to the clipboard for the user
/// to place manually.
public enum DestinationGuard {
    public static func makePlan(
        original: DestinationSnapshot,
        current: DestinationSnapshot,
        capabilities: DestinationCapabilities,
        forceCopyOnly: Bool
    ) -> InsertionPlan {
        // 1. Secure field anywhere in the chain ⇒ copy only, never paste.
        if current.isSecureInput || capabilities.isSecureInput {
            return InsertionPlan(
                strategy: .copyOnly,
                destinationVerified: original.matches(current),
                willInsert: false,
                note: "Focused field is secure; text copied to clipboard instead of inserted."
            )
        }

        // 2. Destination changed ⇒ copy only, never insert into the wrong app.
        if !original.matches(current) {
            let where0 = original.appName ?? original.bundleIdentifier ?? "the original app"
            let where1 = current.appName ?? current.bundleIdentifier ?? "another app"
            return InsertionPlan(
                strategy: .copyOnly,
                destinationVerified: false,
                willInsert: false,
                note: "Destination changed from \(where0) to \(where1); text copied to clipboard."
            )
        }

        // 3. Verified destination ⇒ use the best available strategy.
        let strategy = InsertionPlanner.plan(capabilities: capabilities, forceCopyOnly: forceCopyOnly)
        let willInsert = strategy != .copyOnly
        let note: String? = {
            switch strategy {
            case .accessibility, .clipboardPaste: return nil
            case .copyOnly: return forceCopyOnly
                ? "This app is configured for copy-only; text copied to clipboard."
                : "No text field focused — copied. Click a text field, then dictate."
            }
        }()
        return InsertionPlan(strategy: strategy, destinationVerified: true, willInsert: willInsert, note: note)
    }
}
