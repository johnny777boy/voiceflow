import Foundation
import VoiceFlowCore
import VoiceFlowWhisper

/// Decode audio files through the REAL Whisper path, offline and repeatably.
///
/// This exists because the accuracy question could not be answered. Reading a
/// script aloud once per model measures the READING as much as the model, and
/// the 136-word reference could not resolve a 1-point difference anyway (a
/// single error moves it 0.74). Decoding the SAME audio under both models
/// removes that variance entirely: every utterance becomes a matched pair.
///
///   swift run VoiceFlowBench --audio <dir|file...> [--model <variant>] [--out hyp.txt]
///   swift run VoiceFlowBench --audio bench/ --model openai_whisper-large-v3-v20240930
///
/// It drives `WhisperKitTranscriber` — the production decoder, with the
/// production options and suppress tokens — loaded through
/// `WhisperModelManager.loadPipeline`, the production configuration. A harness
/// that reimplemented any of that would prove nothing.
///
/// ONE DELIBERATE DIFFERENCE, and it is printed at every run: the silence
/// arbiter (the Apple second-opinion engine) is NOT wired, because it lives in
/// the app target. On a short clip the app can therefore deliver text the bench
/// scores as empty. Model comparisons stay valid — both runs lack it equally —
/// but an ABSOLUTE WER from here is not the app's WER.
@main struct Bench {
    static func main() async {
        var audioArgs: [String] = []
        var model = WhisperModelManager.defaultModelVariant
        var out: String?
        var language = "en-US"
        var biasTerms: [String] = []
        var args = Array(CommandLine.arguments.dropFirst())
        while let flag = args.first {
            args.removeFirst()
            switch flag {
            case "--audio":
                while let next = args.first, !next.hasPrefix("-") { audioArgs.append(next); args.removeFirst() }
            case "--model": model = args.first ?? model; if !args.isEmpty { args.removeFirst() }
            case "--out": out = args.first; if !args.isEmpty { args.removeFirst() }
            case "--language": language = args.first ?? language; if !args.isEmpty { args.removeFirst() }
            case "--bias":
                // Terms to feed the recognizer BEFORE it decodes. Only has an
                // effect with -whisperPromptBiasingEnabled YES.
                // Stop at ANY flag, not just "--" ones: a single-dash defaults
                // override ("-whisperPromptBiasingEnabled YES") was being eaten
                // into the term list and fed to the decoder as vocabulary.
                while let next = args.first, !next.hasPrefix("-") { biasTerms.append(next); args.removeFirst() }
            default: break
            }
        }
        guard !audioArgs.isEmpty else {
            print("""
            usage: swift run VoiceFlowBench --audio <dir|file...> [--model <variant>] [--out hyp.txt]

            Decodes each audio file with the production Whisper path and prints one
            hypothesis per line, in filename order — the format Scripts/wer.py scores.
            """)
            exit(2)
        }

        let files = expand(audioArgs)
        guard !files.isEmpty else { print("no audio files found"); exit(2) }

        FileHandle.standardError.write("loading \(model)…\n".data(using: .utf8)!)
        let transcriber = WhisperKitTranscriber()
        // The experiment decodes this audio again under the other model.
        transcriber.retainCaptureFile = true
        do {
            let (pipeline, folder) = try await WhisperModelManager.loadPipeline(variant: model) { fraction in
                FileHandle.standardError.write("  downloading \(Int(fraction * 100))%\r".data(using: .utf8)!)
            }
            transcriber.adopt(pipeline)
            // PROVE which weights are running. The decoder size is the tell:
            // turbo has 4 decoder layers, full large-v3 has 32, so they differ
            // by roughly 5x on disk. Printing the requested name would prove
            // nothing — that is exactly how a turbo-vs-turbo A/B passes for real.
            // PROVE which weights are running, from the model's own config.
            // File size does NOT distinguish them: measured 2026-08-19, turbo
            // and the v20240930 build have byte-identical 328 MB decoders. Only
            // `decoder_layers` tells the truth — full large-v3 has 32, every
            // turbo build has 4. This check exists because the project has now
            // been caught THREE times naming a turbo build as full large-v3.
            var layers = "unknown"
            if let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let n = json["decoder_layers"] as? Int {
                layers = String(n)
                if n <= 8 {
                    FileHandle.standardError.write(
                        "  NOTE: \(n) decoder layers — this is a DISTILLED (turbo) build.\n"
                            .data(using: .utf8)!)
                }
            }
            let proof = "  loaded from   : \(folder.path)\n  decoder layers: \(layers)"
                + "  (full large-v3 = 32, turbo = 4 — these MUST differ between the two runs)\n"
            FileHandle.standardError.write(proof.data(using: .utf8)!)
        } catch {
            print("failed to load \(model): \(error)")
            exit(1)
        }
        let note = "decoding \(files.count) file(s)…\nnote: silence arbiter not wired here"
            + " — short clips may score empty; comparisons stay valid, absolute WER is not the app's\n"
        FileHandle.standardError.write(note.data(using: .utf8)!)

        var lines: [String] = []
        var timings: [Double] = []
        for (i, url) in files.enumerated() {
            let started = Date()
            let capture = AudioCapture(samples: [], sampleRate: 16_000, duration: 0, fileURL: url)
            let context = biasTerms.isEmpty
                ? TranscriptionContext.empty
                : TranscriptionContext(vocabularyTerms: biasTerms)
            var text = ""
            do {
                text = try await transcriber.transcribe(
                    capture, languageCode: language, context: context).text
            } catch {
                text = ""   // an empty line keeps the pairing with the reference intact
                FileHandle.standardError.write("  \(url.lastPathComponent): FAILED \(error)\n".data(using: .utf8)!)
            }
            let elapsed = Date().timeIntervalSince(started)
            timings.append(elapsed)
            lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            FileHandle.standardError.write(
                String(format: "  [%d/%d] %.2fs  %@\n", i + 1, files.count, elapsed,
                       url.lastPathComponent).data(using: .utf8)!)
        }

        let body = lines.joined(separator: "\n") + "\n"
        if let out {
            // A swallowed write failure means the next step scores LAST WEEK's
            // file with full statistical confidence.
            do { try body.write(toFile: out, atomically: true, encoding: .utf8) }
            catch {
                FileHandle.standardError.write("FATAL: could not write \(out): \(error)\n".data(using: .utf8)!)
                exit(4)
            }
            FileHandle.standardError.write("wrote \(out)\n".data(using: .utf8)!)
        } else {
            print(body, terminator: "")
        }
        // Confirm a prompt actually reached the decoder. Biasing silently
        // failing to engage looks identical to biasing not helping — and that
        // exact confusion cost this project eight days.
        let bias = biasTerms.isEmpty
            ? "none"
            : "\(biasTerms.count) terms, prompt \(UserDefaults.standard.bool(forKey: "whisperPromptBiasingEnabled") ? "FED" : "withheld")"
        if !biasTerms.isEmpty {
            // The OFF arm deliberately passes --bias too, so the context (and
            // therefore the echo-discard and voting paths) is identical and the
            // ONLY difference is whether a prompt is fed.
            let enabled = UserDefaults.standard.bool(forKey: "whisperPromptBiasingEnabled")
            let prompt = TranscriptionContext(vocabularyTerms: biasTerms).promptText()
            FileHandle.standardError.write(
                "  bias prompt : \(enabled ? prompt : "(biasing OFF — control arm, context still supplied)")\n"
                    .data(using: .utf8)!)
        }
        // Latency, honestly. The gate in the plan is p95, not mean, and the
        // first decode pays Core ML specialization — reporting a mean that
        // includes it overstates the cost of whichever model runs first.
        let warm = timings.count > 1 ? Array(timings.dropFirst()) : timings
        let sorted = warm.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let summary = String(
            format: "model=%@  bias=%@  files=%d\n"
                + "decode  median %.2fs   p95 %.2fs   max %.2fs   (first decode %.2fs excluded as warm-up)\n",
            model, bias, files.count, median, p95, sorted.last ?? 0, timings.first ?? 0)
        FileHandle.standardError.write(summary.data(using: .utf8)!)
    }

    /// Files in stable filename order, so hypothesis line N always pairs with
    /// reference line N. Sorting is not cosmetic here: an unstable order would
    /// silently misalign every pair and produce a confident, wrong WER.
    static func expand(_ paths: [String]) -> [URL] {
        var out: [URL] = []
        for path in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                out += children
                    .filter { ["wav", "m4a", "mp3", "flac", "caf"].contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
            } else {
                out.append(URL(fileURLWithPath: path))
            }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
