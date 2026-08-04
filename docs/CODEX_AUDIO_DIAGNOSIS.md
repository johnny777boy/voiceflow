# VoiceFlow — Codex Diagnosis Request: mic capture returns 0 samples + verify configurable hotkey

> **Role for Codex:** This is a **diagnosis + verification** request, not a merge review.
> Two things: (A) tell us **why the microphone captures 0 samples** and the fix; (B)
> verify the **configurable push-to-talk hotkey** feature is correct and advise how to
> best let the user pick / hold their own key. The author (Claude) has not been able to
> fix (A) on the user's machine and wants your read.

**Branch:** `feature/system-dictation-daily-use` (also merged to `main`, pushed to
`https://github.com/johnny777boy/voiceflow`)
**Since your round-3 sign-off (`76c3d0b`), these commits are new and UNREVIEWED:**

```
aba89fe wip: robust AudioEngineRecorder (fresh engine, int16 fallback, notice logging) + permission fast-path
f7c97e8 fix: mic/speech permission gate + configurable hotkey + clearer errors
ebcaf50 feat(ui): visible windowed app with Dock icon, logo, and hold-to-talk home screen
```

Changed files: `AudioEngineRecorder.swift`, `SpeechTranscriber.swift`, `AppCoordinator.swift`,
`AppMain.swift`, `HomeView.swift`, `HotkeyRecorderView.swift`, `bundle/Info.plist`,
`Scripts/{build_app.sh,make_icon.swift}`, `bundle/AppIcon.icns`.

Reproduce build/tests:
```bash
swift build            # 0 warnings
swift run VoiceFlowTests   # All 79 tests pass
./Scripts/build_app.sh release   # dist/VoiceFlow.app (ad-hoc, hardened runtime)
```

---

## A) THE BUG — microphone captures 0 samples

**Symptom (on the user's Mac, macOS 26.5.1, Apple Silicon):** holding the push-to-talk
button (or the ⌥Space hotkey) records, then the app shows:

> Error: Audio engine error: No audio was captured — check VoiceFlow's Microphone access and your input device.

That exact string is thrown by `SpeechTranscriber.transcribe` **only when
`audio.samples.isEmpty`** — i.e. `AudioEngineRecorder.stopRecording()` returned an
**empty** sample array. So the AVAudioEngine input tap **never appended a single buffer**.

### What we have already RULED OUT

- ✅ **Microphone entitlement present & hardened runtime on.**
  `codesign -d --entitlements :- /Applications/VoiceFlow.app` → `com.apple.security.device.audio-input = true`; flags `0x10002(adhoc,runtime)`.
- ✅ **NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription** are in `Info.plist`.
- ✅ **Mic + Speech TCC granted** — the in-app permission banner rows for Microphone and
  Speech clear (they only clear when `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`
  and `SFSpeechRecognizer.authorizationStatus() == .authorized`).
- ✅ **Default input device present** — `system_profiler SPAudioDataType` → "Default Input
  Device: Yes", MacBook Pro Microphone, 1ch @ 48000 Hz.
- ✅ **`startRecording()` did not throw** — if it had, the UI would show "Audio engine error: <msg>";
  instead it reached transcription with empty samples, so `engine.start()` returned successfully
  and `stopRecording()` ran.
- ✅ Ad-hoc re-signing resets TCC each rebuild (known); the user re-granted for the current build.

So: engine "starts" fine, but the **input tap callback appends nothing**.

### The exact capture code (`Sources/VoiceFlowApp/Platform/AudioEngineRecorder.swift`)

```swift
func startRecording() throws {
    lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

    let engine = AVAudioEngine()
    self.engine = engine
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    Log.audio.notice("input format rate=\(format.sampleRate) ch=\(format.channelCount)")

    guard format.channelCount > 0, format.sampleRate > 0 else {
        self.engine = nil
        throw VoiceFlowError.audioEngineFailure("Microphone reported no input channels …")
    }
    captureSampleRate = format.sampleRate

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
        guard let self else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        self.lock.lock()
        if let ch = buffer.floatChannelData {
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: frames))
        } else if let ch16 = buffer.int16ChannelData {
            for i in 0..<frames { self.samples.append(Float(ch16[0][i]) / 32_768.0) }
        }
        self.lock.unlock()
    }

    engine.prepare()
    do { try engine.start() }
    catch { input.removeTap(onBus: 0); self.engine = nil; throw VoiceFlowError.audioEngineFailure(error.localizedDescription) }
    isRecording = true
    Log.audio.notice("recording started @ \(self.captureSampleRate) Hz")
}

func stopRecording() throws -> AudioCapture {
    guard isRecording, let engine else { return AudioCapture(samples: [], sampleRate: captureSampleRate, duration: 0) }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    isRecording = false
    lock.lock(); let captured = samples; lock.unlock()
    Log.audio.notice("recording stopped: \(captured.count) samples")
    return AudioCapture(samples: captured, sampleRate: captureSampleRate, duration: /*…*/ 0)
}
```

### CRITICAL CONTEXT — the call path / threading

`startRecording()` / `stopRecording()` are **not** called on the main thread. They are
invoked from **`DictationController` (a Swift `actor`)**:

```swift
public actor DictationController {
    public func beginRecording() throws {
        pendingSnapshot = activeApp.captureSnapshot()   // main-safe? see below
        recordStartTime = time.now()
        try audio.startRecording()                      // <-- runs on the ACTOR executor (background)
    }
    public func finishRecording() async throws -> DictationResult {
        let capture = try audio.stopRecording()         // <-- ACTOR executor
        let transcription = try await transcriber.transcribe(capture, languageCode: …)
        …
    }
}
```

`AppCoordinator` (a `@MainActor` ObservableObject) calls the actor via `await`:

```swift
private func reconcile() {
    guard !reconciling else { return }
    reconciling = true
    Task { @MainActor in
        defer { reconciling = false }
        while recordingIntent != isRecording {
            if recordingIntent { await beginRecordingTransition(); if !isRecording { break } }
            else               { await finishRecordingTransition() }
        }
    }
}
private func beginRecordingTransition() async {
    if !(microphoneGranted && speechGranted) {           // fast-path avoids prompt desync
        if let msg = await ensureCapturePermissions() { … return }
    }
    do { try await controller.beginRecording(); isRecording = true; … }
    catch { … }
}
```

So **AVAudioEngine is created, `installTap`-ed, and `start()`-ed on the actor's
cooperative background thread, not the main thread.**

### Author's prioritized hypotheses (please confirm/refute)

1. **Off-main AVAudioEngine start (most suspected).** The engine + tap are set up and
   started on the `DictationController` actor's background executor. On macOS, do the
   input-node IO callbacks / the tap require the engine to be started on the **main
   thread / a thread with a live run loop**? If so, the tap never fires ⇒ 0 samples with
   no throw — matching the symptom exactly. *Proposed fix:* marshal engine
   setup/start/stop to the main thread (e.g. run the recorder on `@MainActor`, or
   `DispatchQueue.main.sync` the engine ops — safe here since the caller is off-main).

2. **Tap-only input node not driving IO.** Is `installTap` on `inputNode` + `start()`
   sufficient on macOS 26, or must the graph be pulled (touch `engine.mainMixerNode`, or
   connect `inputNode → mainMixerNode`) for the input IO to run?

3. **`outputFormat(forBus:0)` vs `inputFormat(forBus:0)`.** Is `outputFormat` the right
   tap format here, or should we tap with `inputFormat` (hardware format) / a converted
   standard format? Could `outputFormat` return a valid-looking but non-pulling format?

4. **Press/release timing.** With the reconcile model, could begin and finish still
   collapse so the engine runs for ~0 ms? (We think not for a held button, but please
   sanity-check the `reconcile()` logic.)

5. **`captureSnapshot()` inside `beginRecording` (actor)** calls Accessibility/NSWorkspace
   APIs off the main thread — could that block/throw and abort before/around the tap?

**Please tell us the actual cause and the concrete fix (with the corrected
`AudioEngineRecorder` / call-site if threading is the issue).** A live-streaming
`SFSpeechAudioBufferRecognitionRequest` fed from the tap is acceptable if you think the
record-then-transcribe buffer approach is the problem — but note the failure is at
*capture* (0 samples), upstream of transcription.

---

## B) FEATURE TO VERIFY — user wants to choose their own push-to-talk key

The user wants to **pick and rebind the key they press-and-hold** (like Wispr Flow),
not just the default ⌥Space. Implemented as `HotkeyRecorderView` (the keyboard chip in
the window header): click it, press any combo, it captures and re-registers the global
hotkey.

`Sources/VoiceFlowApp/UI/HotkeyRecorderView.swift` (core):

```swift
private func start() {
    capturing = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
        guard let config = Self.configuration(from: event, isPushToTalk: current.isPushToTalk) else { return nil }
        onCommit(config)   // -> AppCoordinator.applySettings -> re-registers GlobalHotkeyManager
        stop()
        return nil         // swallow the key
    }
}

static func configuration(from event: NSEvent, isPushToTalk: Bool) -> HotkeyConfiguration? {
    var mask: UInt32 = 0
    let f = event.modifierFlags
    if f.contains(.command) { mask |= HotkeyMatcher.carbonCommand }
    if f.contains(.shift)   { mask |= HotkeyMatcher.carbonShift }
    if f.contains(.option)  { mask |= HotkeyMatcher.carbonOption }
    if f.contains(.control) { mask |= HotkeyMatcher.carbonControl }
    return HotkeyConfiguration(keyCode: UInt32(event.keyCode), modifierFlags: mask,
                               displayString: displayString(…), isPushToTalk: isPushToTalk)
}
```

The global tap that consumes this config is `GlobalHotkeyManager` (uses the already-
reviewed pure `HotkeyMatcher.decode/matches/shouldEndChord`; handles `.keyDown/.keyUp/.flagsChanged`
and auto-repeat).

**Please verify and advise:**

- Is `NSEvent.addLocalMonitorForEvents(.keyDown)` the right capture path, and does
  returning `nil` reliably swallow the key so it doesn't type while capturing?
- The user specifically wants **hold-to-talk on their chosen key.** For keys that also
  produce text (e.g. the default **⌥Space inserts a non-breaking space** because the
  global tap is `.listenOnly`), what's the right approach — switch the global
  `CGEvent.tapCreate` to an **active tap that consumes** the matched key events, restrict
  to non-text keys, or support **pure-modifier / fn** triggers? Please recommend the
  concrete change (and whether `.listenOnly` → default tap + returning `nil` is safe).
- Any issue rebinding at runtime (unregister/re-register the CGEvent tap in
  `GlobalHotkeyManager.register`)?

---

## What we need back from Codex

1. **Root cause of the 0-sample capture** + the exact code fix (threading? graph? format?).
2. **Verification of the hotkey rebinding** + the recommended way to make a chosen
   hold-to-talk key not type characters (consume the event / restrict keys).
3. Confirm `swift build` (0 warnings) and `swift run VoiceFlowTests` (79 pass) still hold.

All code is on the branch and on GitHub. Thanks.

---

## 9. Resolution — Codex round-2 review applied

> Note: Codex's round-2 pass reviewed a stale checkout (it flagged the two compile
> errors at `LiveSpeechDictation.swift:91/116` that were already fixed + pushed on
> `d1b1d51`). Its substantive recommendations were applied:

- **Capture bug is resolved** in practice — the app now transcribes real speech. Root
  fixes: fresh `AVAudioEngine` per recording, and (this round) **AVAudioEngine lifecycle
  runs on the main thread** via an `onMain` marshal in `LiveSpeechDictation`
  (`start/stopRecording` are invoked from the `DictationController` actor, off-main).
- **Format handling** per Codex: guard on `input.inputFormat(forBus:0)` (hardware
  availability), tap with `input.outputFormat(forBus:0)`.
- **Long dictation**: switched to live streaming (`LiveSpeechDictation` feeds
  `SFSpeechAudioBufferRecognitionRequest` continuously with partial results) so
  paragraphs aren't truncated. (On-device recognition still has a ~1-min practical
  ceiling; multi-minute needs segmentation — noted as follow-up.)
- **Global hotkey now consumes the key** per Codex: `CGEvent.tapCreate` switched from
  `.listenOnly` to `.defaultTap`; `handle(...)` returns whether to consume, and the
  callback returns `nil` for matched key-down / auto-repeat / key-up so the push-to-talk
  key does **not** type a character. `flagsChanged` is never consumed. Added
  `tapDisabledByTimeout/UserInput` re-enable. Auto-repeat filtered for toggle mode.
- **In-app button** is tap-to-toggle; **hotkey** is hold-to-talk.

Pure-modifier / fn triggers were intentionally NOT added (Codex advised against bolting
them onto the keyDown recorder); the recorder captures modifiers + one non-modifier key.
