import Foundation
import VoiceFlowTestKit

// Entry point for the VoiceFlow test suite. Each subsystem contributes a
// `run<Name>Tests(_:)` function; they are all invoked here. The process exits
// non-zero if any assertion fails.

let suite = TestSuite()

print("Running VoiceFlow test suite…\n")

runModelTests(suite)
runVocabularyTests(suite)
runCleanupTests(suite)
// Subsystem runners are appended here as each area lands:
// runDestinationGuardTests, runInsertionPlannerTests, runHistoryStoreTests,
// runSecurityTests, runControllerTests

suite.finish()
