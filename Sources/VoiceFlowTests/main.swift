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
runInsertionPlannerTests(suite)
runDestinationGuardTests(suite)
runHistoryStoreTests(suite)
runSecurityTests(suite)
runHotkeyTests(suite)
runControllerTests(suite)
runFallbackTranscriberTests(suite)
runVerbatimTests(suite)
runFuzzTests(suite)
runDoubtTests(suite)
runLeadingSilenceTests(suite)
runPersonalConfusionTests(suite)
runContextBiasTests(suite)
runMetricsTests(suite)
runLatencyTests(suite)
runLearningTests(suite)
runVotingTests(suite)

suite.finish()
