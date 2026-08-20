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
                while let next = args.first, !next.hasPrefix("--") { audioArgs.append(next); args.removeFirst() }
            case "--model": model = args.first ?? model; if !args.isEmpty { args.removeFirst() }
            case "--out": out = args.first; if !args.isEmpty { args.removeFirst() }
            case "--language": language = args.first ?? language; if !args.isEmpty { args.removeFirst() }
            case "--bias":
                // Terms to feed the recognizer BEFORE it decodes. Only has an
                // effect with -whisperPromptBiasingEnabled YES.
                while let next = args.first, !next.hasPrefix("--") { biasTerms.append(next); args.removeFirst() }
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
            let pipeline = try await WhisperModelManager.loadPipeline(variant: model) { fraction in
                FileHandle.standardError.write("  downloading \(Int(fraction * 100))%\r".data(using: .utf8)!)
            }
            transcriber.adopt(pipeline)
        } catch {
            print("failed to load \(model): \(error)")
            exit(1)
        }
        FileHandle.standardError.write("decoding \(files.count) file(s)…\n".data(using: .utf8)!)
        FileHandle.standardError.write(
            "note: silence arbiter not wired here — short clips may score empty; "
            + "comparisons stay valid, absolute WER is not the app's\n".data(using: .utf8)!)

        var lines: [String] = []
        var totalSeconds = 0.0
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
            totalSeconds += elapsed
            lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            FileHandle.standardError.write(
                String(format: "  [%d/%d] %.2fs  %@\n", i + 1, files.count, elapsed,
                       url.lastPathComponent).data(using: .utf8)!)
        }

        let body = lines.joined(separator: "\n") + "\n"
        if let out {
            try? body.write(toFile: out, atomically: true, encoding: .utf8)
            FileHandle.standardError.write("wrote \(out)\n".data(using: .utf8)!)
        } else {
            print(body, terminator: "")
        }
        let bias = biasTerms.isEmpty ? "none" : "\(biasTerms.count) terms"
        FileHandle.standardError.write(
            String(format: "model=%@  bias=%@  files=%d  decode=%.1fs total (%.2fs mean)\n",
                   model, bias, files.count, totalSeconds,
                   totalSeconds / Double(max(files.count, 1))).data(using: .utf8)!)
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
