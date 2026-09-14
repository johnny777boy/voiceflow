import Foundation

/// What Accessibility could determine about the focused field.
public enum FocusedFieldSecurity: Equatable, Sendable {
    /// AX read the element and it IS a password field (role/subrole says so).
    case secure
    /// AX read the element and it is plainly NOT a password field.
    case notSecure
    /// AX could not read the element at all — nothing is known about it.
    case unreadable
}

/// Decides whether automated insertion (AX-set or synthetic ⌘V) must be refused.
///
/// The guarantee: **never deliver text into a secure (password) field.**
///
/// macOS secure input is a *system-wide* flag. Any app that focuses a password
/// field turns it on for every app, and an app can leave it on after the field
/// loses focus — Arc did exactly that on 2026-09-14, and because the old rule
/// refused on the flag alone, 12 consecutive dictations into an ordinary chat
/// box became copy-only. One stuck app could silently disable dictation
/// everywhere, with no indication of why.
///
/// So the flag is no longer a veto on its own. It decides only the case where
/// Accessibility cannot see the focused field — which is precisely the hole the
/// flag was added to close (a secure field that exposes nothing to AX). When AX
/// *can* read the field, its role/subrole is the stronger, field-specific
/// signal and it decides.
///
/// | focused field | system flag | result   |
/// |---------------|-------------|----------|
/// | `.secure`     | either      | refuse   |
/// | `.notSecure`  | either      | insert   |
/// | `.unreadable` | on          | refuse   |
/// | `.unreadable` | off         | insert   |
///
/// Accepted risk: an app that exposes a real password field to Accessibility
/// while labelling it with a non-secure role would now be inserted into. That
/// requires the app to actively mislabel its own accessibility tree; anything
/// merely unreadable still fails closed.
public enum SecureInputVerdict {
    public static func mustRefuseInsertion(
        systemSecureInputEnabled: Bool,
        focusedField: FocusedFieldSecurity
    ) -> Bool {
        switch focusedField {
        case .secure:
            // The field itself says password. Strongest signal; always refuse.
            return true
        case .notSecure:
            // AX read the field and it is an ordinary text box. Trust that over a
            // process-wide flag some other app may have left on.
            return false
        case .unreadable:
            // Nothing known about the field. The system flag is the only signal
            // left, so fail closed while it is on.
            return systemSecureInputEnabled
        }
    }
}
