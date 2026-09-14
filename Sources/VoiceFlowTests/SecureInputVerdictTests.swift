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
}
