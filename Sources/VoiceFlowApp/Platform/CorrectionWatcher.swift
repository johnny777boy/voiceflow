import Foundation
import AppKit
import ApplicationServices
import VoiceFlowCore

/// Watches the field we just dictated into, briefly, to learn from what the user
/// fixes by hand.
///
/// How it works: right after insertion it snapshots the focused element's text;
/// a few seconds later it reads the same element again. If exactly one word
/// changed, and that word was one WE inserted, the pair is counted as a
/// correction. At three occurrences it becomes a *suggestion* the user can accept
/// in Settings — never an automatic vocabulary entry.
///
/// Privacy: the snapshot lives in memory for the length of the window, is never
/// written anywhere, and only the two changed words can ever be persisted (and
/// only after they recur). Secure fields are never watched.
@MainActor
final class CorrectionWatcher {
    /// How long after insertion to look. Long enough to catch "oh, that's wrong"
    /// and short enough that the text is still the dictation rather than a
    /// paragraph built on top of it.
    private let window: TimeInterval
    private let store: SuggestedVocabularyStore
    private let onEdit: (UUID, Bool) -> Void
    private let onSuggestion: (VocabularySuggestion) -> Void

    private var pending: Task<Void, Never>?

    init(
        store: SuggestedVocabularyStore,
        window: TimeInterval = 6,
        onEdit: @escaping (UUID, Bool) -> Void,
        onSuggestion: @escaping (VocabularySuggestion) -> Void
    ) {
        self.store = store
        self.window = window
        self.onEdit = onEdit
        self.onSuggestion = onSuggestion
    }

    /// Stop watching (a new dictation started, or the app is going away).
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Begin watching the field that just received `insertedText`.
    func watch(recordID: UUID, insertedText: String) {
        cancel()
        guard !insertedText.isEmpty else { return }
        guard let element = AX.focusedElement(), !Self.isSecure(element) else { return }
        guard let before = AX.string(element, kAXValueAttribute) else { return }   // AX-blind field
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.window ?? 6) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Only trust the read if the user is still in the same app; otherwise
            // the element may be gone or reused for something else entirely.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            guard let after = AX.string(element, kAXValueAttribute) else { return }
            self.evaluate(recordID: recordID, insertedText: insertedText, before: before, after: after)
        }
    }

    private func evaluate(recordID: UUID, insertedText: String, before: String, after: String) {
        guard CorrectionDetector.textWasEdited(inserted: before, final: after) else { return }
        onEdit(recordID, true)

        guard let correction = CorrectionDetector.detect(inserted: before, final: after) else { return }
        // The changed word must be one WE put there — otherwise the user fixed
        // their own typing and it says nothing about the recognizer.
        guard CorrectionDetector.containsWord(correction.heard, in: insertedText) else { return }

        Log.cleanup.notice("Correction observed (\(correction.heard.count, privacy: .public)→\(correction.corrected.count, privacy: .public) chars)")
        if let ready = store.record(correction) {
            onSuggestion(ready)
        }
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        if AX.string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        return AX.string(element, kAXRoleAttribute) == "AXSecureTextField"
    }
}
