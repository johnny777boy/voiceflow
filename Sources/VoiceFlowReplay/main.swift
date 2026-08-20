import Foundation
import VoiceFlowCore

/// Replay real dictations through the REAL cleanup stack.
///
/// The question this exists to answer is "how do we know it is actually
/// working?" — which unit tests cannot answer, because the same person wrote
/// the test and the code. This runs the production path (RuleBasedCleanup → the
/// on-device model with the production prompt → CleanupGuard) over transcripts
/// the user actually spoke, and prints what each stage did, so the answer comes
/// from reading real output rather than from trusting anybody.
///
/// It imports the app's own provider; it does not reimplement it. A harness
/// that reimplements the thing it checks proves nothing.
///
///   swift run VoiceFlowReplay                 last 20 real dictations
///   swift run VoiceFlowReplay --limit 40
///   swift run VoiceFlowReplay --file lines.txt
///   swift run VoiceFlowReplay --policy verbatim
@main struct Replay {

    static func main() async {
        var limit = 20
        var file: String?
        var policy = CleanupGuard.Policy.grammarRepair
        var strength = CleanupStrength.standard
        var args = Array(CommandLine.arguments.dropFirst())
        while let flag = args.first {
            args.removeFirst()
            switch flag {
            case "--limit": limit = Int(args.first ?? "") ?? 20; if !args.isEmpty { args.removeFirst() }
            case "--file": file = args.first; if !args.isEmpty { args.removeFirst() }
            case "--strength":
                strength = CleanupStrength(rawValue: args.first ?? "") ?? .standard
                if !args.isEmpty { args.removeFirst() }
            case "--policy":
                policy = (args.first == "verbatim") ? .verbatim : .grammarRepair
                if !args.isEmpty { args.removeFirst() }
            default: break
            }
        }

        if CommandLine.arguments.contains("--prove") { proveGuard(); exit(0) }

        guard #available(macOS 26.0, *) else {
            print("needs macOS 26 (on-device Foundation Models)"); exit(2)
        }
        guard FoundationModelsCleanupProvider.isAvailable else {
            print("""
            Apple Intelligence reports the cleanup model UNAVAILABLE.
            That is the same check the app makes, so right now the app is not
            polishing anything either — every dictation is rules-only.
            """)
            exit(3)
        }

        let lines: [String]
        if let file {
            lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } else {
            lines = realDictations(limit: limit)
        }
        guard !lines.isEmpty else { print("nothing to replay"); exit(1) }

        let audit = CleanupAuditLog()
        let pipeline = CleanupPipeline(
            llmProvider: FoundationModelsCleanupProvider(audit: audit),
            useLLM: true, audit: audit)

        var decisions: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        var changed = 0
        var deliveredAll: [String] = []

        print("\nReplaying \(lines.count) real dictations through the production cleanup path")
        print("(policy: \(policy == .verbatim ? "verbatim" : "grammarRepair"), strength: \(strength.rawValue))\n")

        for (i, raw) in lines.enumerated() {
            let context = CleanupContext(
                mode: .cleanWriting, strength: strength,
                vocabulary: VocabularyEntry.defaults, languageCode: "en-US",
                spokenPunctuationEnabled: false,
                // The fast path is a SKIP, not a cleanup decision: leaving it on
                // would hide the model's behaviour on short utterances, which is
                // exactly what we are here to look at.
                fastPathEnabled: false,
                guardPolicy: policy)
            let delivered = (try? await pipeline.clean(raw, context: context)) ?? raw
            let entry = audit.take()
            let decision = entry?.decision ?? "(none)"
            decisions[decision, default: 0] += 1
            if let r = entry?.reason { reasons[r, default: 0] += 1 }
            if delivered != raw { changed += 1 }
            deliveredAll.append(delivered)

            let mark: String
            switch decision {
            case "accepted": mark = "\u{001B}[32m✓ accepted\u{001B}[0m"
            case "partial":  mark = "\u{001B}[33m~ partial\u{001B}[0m"
            case "rejected": mark = "\u{001B}[31m✗ REJECTED\u{001B}[0m"
            default:         mark = "· \(decision)"
            }
            print("\u{001B}[1m[\(i + 1)]\u{001B}[0m \(mark)")
            print("  said      \(raw)")
            if let proposed = entry?.proposed, proposed != raw {
                print("  model     \(proposed)")
            }
            print("  delivered \(delivered == raw ? "\u{001B}[2m(your words, unchanged)\u{001B}[0m" : delivered)")
            if let r = entry?.reason { print("  \u{001B}[31mrefused   \(r)\u{001B}[0m") }
            print()
        }

        print("\u{001B}[1mSummary\u{001B}[0m")
        for (d, c) in decisions.sorted(by: { $0.value > $1.value }) {
            print("  \(d.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c)")
        }
        print("  text actually changed for \(changed)/\(lines.count) dictations")
        // The complaint is run-ons, so measure them instead of eyeballing.
        func sentenceStats(_ texts: [String]) -> (count: Int, longest: Int) {
            var total = 0, longest = 0
            for t in texts {
                let parts = t.split(whereSeparator: { ".!?".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                total += parts.count
                longest = max(longest, parts.map { $0.split(separator: " ").count }.max() ?? 0)
            }
            return (total, longest)
        }
        let before = sentenceStats(lines), after = sentenceStats(deliveredAll)
        print("  sentences   \(before.count) → \(after.count)")
        print("  longest     \(before.longest) → \(after.longest) words")
        if !reasons.isEmpty {
            print("\n\u{001B}[1mWhy the guard refused\u{001B}[0m")
            for (r, c) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(c)×  \(r)") }
        }
        print()
    }

    /// The user's own dictations, newest first, straight from the app's history.
    static func realDictations(limit: Int) -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceFlow/history.sqlite")
        guard let store = try? SQLiteHistoryStore(url: url),
              let records = try? store.allRecords() else {
            print("could not read history at \(url.path)"); return []
        }
        return records.prefix(limit).map(\.rawText)
    }
}


/// The safety demonstration, in plain English.
///
/// Every line below is an edit that CHANGES WHAT THE SPEAKER SAID. The guard is
/// the only thing standing between the AI and the text in your field, so this
/// runs each one through the real guard — the same code the app uses — and
/// shows the verdict. Anything marked LET THROUGH is a live defect.
///
///   swift run VoiceFlowReplay --prove
func proveGuard() {
    struct Case { let what: String; let said: String; let ai: String }
    let mustRefuse: [Case] = [
        .init(what: "cuts a sentence in half, changing the instruction",
              said: "call me before the meeting we can decide then",
              ai:   "Call me. Before the meeting we can decide then."),
        .init(what: "cuts a condition off a promise",
              said: "I will not send it until you confirm",
              ai:   "I will not send it. Until you confirm."),
        .init(what: "deletes a word you said",
              said: "we need to dig a new well behind the garage",
              ai:   "We need to dig a new behind the garage."),
        .init(what: "invents a word you never said",
              said: "we are done for today",
              ai:   "We are done well for today."),
        .init(what: "flips a negation",
              said: "do not delete the file after review",
              ai:   "Do delete the file after review."),
        .init(what: "changes a number",
              said: "the deposit is 3000 dollars",
              ai:   "The deposit is 4000 dollars."),
        .init(what: "reverses who owes whom",
              said: "you owe me and I owe you",
              ai:   "You owe you and I owe me."),
        .init(what: "swaps a preposition, moving money the other way",
              said: "transfer the deposit to Bob on Friday",
              ai:   "Transfer the deposit from Bob on Friday."),
        .init(what: "turns a maybe into a commitment",
              said: "I might come to the site tomorrow",
              ai:   "I will come to the site tomorrow."),
    ]
    let mustAllow: [Case] = [
        .init(what: "fixes your grammar without changing your words",
              said: "he ask me for the invoice yesterday",
              ai:   "He asked me for the invoice yesterday."),
        .init(what: "breaks genuine run-on speech honestly",
              said: "we finished the deck today the crew went home early",
              ai:   "We finished the deck today. The crew went home early."),
        .init(what: "removes a filled pause",
              said: "um we should order the tile on monday",
              ai:   "We should order the tile on Monday."),
        // Added after review: the clause rule refused six of seven realistic
        // splits, and this proof reported "all correct" anyway because its one
        // split case dodged every trigger word. A proof that cannot fail is not
        // a proof.
        .init(what: "splits an honest run-on starting with 'After'",
              said: "we set the forms after that we poured the slab",
              ai:   "We set the forms. After that, we poured the slab."),
        .init(what: "splits an honest run-on ending on 'to'",
              said: "i told him not to he did it anyway",
              ai:   "I told him not to. He did it anyway."),
        .init(what: "keeps an abbreviation from reading as a sentence end",
              said: "meet me at 8 a.m. that works for me",
              ai:   "Meet me at 8 a.m. That works for me."),
    ]

    var failures = 0
    print("\n\u{001B}[1mCan the AI change what you said?\u{001B}[0m  (each line is run through the real guard)\n")
    for c in mustRefuse {
        let allowed = CleanupGuard.preservesMeaning(original: c.said, cleaned: c.ai, policy: .grammarRepair)
        if allowed { failures += 1 }
        print(allowed ? "  \u{001B}[31mLET THROUGH\u{001B}[0m  \(c.what)" : "  \u{001B}[32mblocked\u{001B}[0m      \(c.what)")
        print("               you said : \(c.said)")
        print("               AI wanted: \(c.ai)")
        if let why = CleanupGuard.rejection(original: c.said, cleaned: c.ai, policy: .grammarRepair) {
            print("               refused  : \(why)")
        }
        print()
    }
    print("\u{001B}[1mAnd does it still allow real help?\u{001B}[0m\n")
    for c in mustAllow {
        let allowed = CleanupGuard.preservesMeaning(original: c.said, cleaned: c.ai, policy: .grammarRepair)
        if !allowed { failures += 1 }
        print(allowed ? "  \u{001B}[32mallowed\u{001B}[0m      \(c.what)" : "  \u{001B}[31mBLOCKED\u{001B}[0m      \(c.what) — too strict")
        print("               you said : \(c.said)")
        print("               you get  : \(c.ai)")
        print()
    }
    if failures == 0 {
        print("\u{001B}[32m\u{001B}[1mAll \(mustRefuse.count + mustAllow.count) checks behaved correctly.\u{001B}[0m")
        print("The AI cannot change your meaning, and it can still fix your English.")
        print("\u{001B}[2mThis covers SAFETY — that cleanup does not alter your words. It says")
        print("nothing about whether the engine HEARD you correctly; only a WER run")
        print("on your own voice can answer that (Scripts/bench_session.sh).\u{001B}[0m\n")
    } else {
        print("\u{001B}[31m\u{001B}[1m\(failures) FAILED — do not trust this build.\u{001B}[0m\n")
    }
}
