import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

/// macOS secure input is a SYSTEM-WIDE flag: any app that focuses a password
/// field turns it on for every app, and a buggy app can leave it on (Arc did,
/// 2026-09-14, which turned 12 consecutive dictations into copy-only).
/// Refusing insertion on that flag alone therefore lets one stuck app disable
/// dictation everywhere. These tests pin the narrower rule: the flag only
/// decides the case where Accessibility genuinely cannot see the focused field.
func runSecureInputVerdictTests(_ s: TestSuite) {

    // MARK: The field is readable and IS a password field — always refuse.

    s.test("Refuses a secure field when system secure input is off") { s in
        s.expect(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: false, focusedField: .secure))
    }

    s.test("Refuses a secure field when system secure input is on") { s in
        s.expect(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: true, focusedField: .secure))
    }

    // MARK: The field is readable and is NOT a password field — insert.

    s.test("Inserts into a readable non-secure field when system secure input is off") { s in
        s.expectFalse(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: false, focusedField: .notSecure))
    }

    /// THE REGRESSION. Before the fix this returned true, so a stuck app holding
    /// secure input (Arc) forced copy-only into every plainly-normal text box.
    s.test("Inserts into a readable non-secure field even while another app holds secure input") { s in
        s.expectFalse(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: true, focusedField: .notSecure))
    }

    // MARK: Accessibility cannot see the field — the flag is the only signal left.

    s.test("Refuses an unreadable field while system secure input is on") { s in
        s.expect(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: true, focusedField: .unreadable))
    }

    s.test("Inserts into an unreadable field when system secure input is off") { s in
        s.expectFalse(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: false, focusedField: .unreadable))
    }

    // MARK: - Classification (C001)
    //
    // `AX.string` returns nil both when an attribute is absent and when the read
    // FAILS. Collapsing that into "not secure" means a password field whose
    // role/subrole cannot be read is treated as an ordinary text box. Bool cannot
    // express "I could not tell", so the classification must.

    s.test("Classifies a field whose role and subrole are both unreadable as unreadable") { s in
        s.expectEqual(FocusedFieldSecurity.classify(role: nil, subrole: nil), .unreadable)
    }

    s.test("Classifies the secure text field subrole as secure") { s in
        s.expectEqual(FocusedFieldSecurity.classify(role: "AXTextField", subrole: "AXSecureTextField"), .secure)
    }

    s.test("Classifies the secure text field role as secure") { s in
        s.expectEqual(FocusedFieldSecurity.classify(role: "AXSecureTextField", subrole: nil), .secure)
    }

    /// The common case for Electron/web boxes: a readable role, no subrole. This
    /// must stay .notSecure — treating it as unreadable would re-break insertion
    /// for every chat box the moment any app holds secure input.
    s.test("Classifies a readable ordinary role with no subrole as not secure") { s in
        s.expectEqual(FocusedFieldSecurity.classify(role: "AXTextArea", subrole: nil), .notSecure)
    }

    s.test("Classifies a readable non-secure subrole with no role as not secure") { s in
        s.expectEqual(FocusedFieldSecurity.classify(role: nil, subrole: "AXStandardWindow"), .notSecure)
    }

    /// THE C001 REGRESSION, end to end.
    s.test("Refuses a field with unreadable attributes while another app holds secure input") { s in
        let field = FocusedFieldSecurity.classify(role: nil, subrole: nil)
        s.expect(SecureInputVerdict.mustRefuseInsertion(
            systemSecureInputEnabled: true, focusedField: field))
    }
}
