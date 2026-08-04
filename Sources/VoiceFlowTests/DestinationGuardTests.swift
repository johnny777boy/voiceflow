import Foundation
import VoiceFlowCore
import VoiceFlowTestKit

private func caps(ax: Bool = true, paste: Bool = true, secure: Bool = false) -> DestinationCapabilities {
    DestinationCapabilities(supportsAccessibilityInsertion: ax, allowsSyntheticPaste: paste, isSecureInput: secure)
}

func runInsertionPlannerTests(_ s: TestSuite) {
    s.test("Planner prefers accessibility when available") { s in
        s.expectEqual(InsertionPlanner.plan(capabilities: caps(ax: true, paste: true), forceCopyOnly: false), .accessibility)
    }
    s.test("Planner falls back to clipboard paste when no AX") { s in
        s.expectEqual(InsertionPlanner.plan(capabilities: caps(ax: false, paste: true), forceCopyOnly: false), .clipboardPaste)
    }
    s.test("Planner falls back to copy-only when nothing available") { s in
        s.expectEqual(InsertionPlanner.plan(capabilities: caps(ax: false, paste: false), forceCopyOnly: false), .copyOnly)
    }
    s.test("Planner returns copy-only for secure field") { s in
        s.expectEqual(InsertionPlanner.plan(capabilities: caps(ax: true, paste: true, secure: true), forceCopyOnly: false), .copyOnly)
    }
    s.test("Planner honors force copy-only") { s in
        s.expectEqual(InsertionPlanner.plan(capabilities: caps(ax: true, paste: true), forceCopyOnly: true), .copyOnly)
    }
}

func runDestinationGuardTests(_ s: TestSuite) {
    let terminal = MockActiveAppProvider.terminal()

    s.test("Guard inserts via accessibility when destination verified") { s in
        let plan = DestinationGuard.makePlan(original: terminal, current: terminal, capabilities: caps(), forceCopyOnly: false)
        s.expectEqual(plan.strategy, .accessibility)
        s.expect(plan.destinationVerified)
        s.expect(plan.willInsert)
        s.expectNil(plan.note)
    }

    s.test("Guard blocks insertion when app changed, copies instead") { s in
        let plan = DestinationGuard.makePlan(original: terminal, current: MockActiveAppProvider.safari(), capabilities: caps(), forceCopyOnly: false)
        s.expectEqual(plan.strategy, .copyOnly)
        s.expectFalse(plan.destinationVerified)
        s.expectFalse(plan.willInsert)
        s.expectNotNil(plan.note)
    }

    s.test("Guard never inserts into a secure field") { s in
        let secure = MockActiveAppProvider.terminal(secure: true)
        let plan = DestinationGuard.makePlan(original: terminal, current: secure, capabilities: caps(secure: true), forceCopyOnly: false)
        s.expectEqual(plan.strategy, .copyOnly)
        s.expectFalse(plan.willInsert)
        s.expect(plan.note?.contains("secure") ?? false)
    }

    s.test("Guard honors per-app copy-only even when verified") { s in
        let plan = DestinationGuard.makePlan(original: terminal, current: terminal, capabilities: caps(), forceCopyOnly: true)
        s.expectEqual(plan.strategy, .copyOnly)
        s.expectFalse(plan.willInsert)
        s.expect(plan.destinationVerified)
    }

    s.test("Guard uses clipboard paste when only paste is available") { s in
        let plan = DestinationGuard.makePlan(original: terminal, current: terminal, capabilities: caps(ax: false, paste: true), forceCopyOnly: false)
        s.expectEqual(plan.strategy, .clipboardPaste)
        s.expect(plan.willInsert)
    }
}
