import SwiftUI
import VoiceFlowCore

/// The main app window. A visible, mouse-usable surface for dictation: hold the
/// big button (or the global hotkey) to talk, switch modes, and see history.
struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    private static let brand = LinearGradient(
        colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.58, green: 0.30, blue: 0.92)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 18) {
            header
            if !coordinator.microphoneGranted || !coordinator.speechGranted
                || !coordinator.accessibilityGranted || !coordinator.inputMonitoringGranted {
                permissionBanner
            }
            talkButton
            statusBlock
            modePicker
            Divider().opacity(0.5)
            historySection
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity, alignment: .top)
        .background(background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            logoMark.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("VoiceFlow").font(.title3.bold())
                Text("Push-to-talk dictation").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HotkeyRecorderView(current: coordinator.settings.hotkey) { newHotkey in
                var s = coordinator.settings; s.hotkey = newHotkey; coordinator.applySettings(s)
            }
            Button { openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.body)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var logoMark: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Self.brand)
            .overlay(Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
    }

    // Show a row per permission that still needs granting.
    @ViewBuilder private var permissionBanner: some View {
        VStack(spacing: 6) {
            if !coordinator.microphoneGranted {
                permissionRow("Microphone", "mic.fill", "Needed to record your voice.", "Privacy_Microphone")
            }
            if !coordinator.speechGranted {
                permissionRow("Speech Recognition", "waveform", "Needed to turn speech into text.", "Privacy_SpeechRecognition")
            }
            if !coordinator.accessibilityGranted {
                permissionRow("Accessibility", "hand.point.up.left.fill", "Needed for the global hotkey and inserting into other apps.", "Privacy_Accessibility")
            }
            if !coordinator.inputMonitoringGranted {
                permissionRow("Input Monitoring", "keyboard", "Needed for the global push-to-talk key.", "Privacy_ListenEvent")
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionRow(_ title: String, _ icon: String, _ why: String, _ pane: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Enable \(title)").font(.caption.weight(.semibold))
                Text(why).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Open") { coordinator.openPrivacySettings(pane) }.font(.caption)
        }
    }

    // MARK: - Talk button (tap to start/stop; hotkey is hold-to-talk)

    private static let recordGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.38, blue: 0.42), Color(red: 0.92, green: 0.22, blue: 0.45)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private var talkButton: some View {
        VStack(spacing: 14) {
            ZStack {
                // Live glow ring that breathes with the mic level while recording.
                if coordinator.isRecording {
                    Circle()
                        .fill(Self.recordGradient)
                        .frame(width: 150, height: 150)
                        .scaleEffect(1 + 0.16 * min(1, coordinator.audioLevel))
                        .opacity(0.22)
                        .blur(radius: 14)
                        .animation(.easeOut(duration: 0.12), value: coordinator.audioLevel)
                }
                // Tap-to-toggle button: tap to start, tap again to stop.
                Button(action: { coordinator.toggleRecording() }) {
                    ZStack {
                        Circle()
                            .fill(coordinator.isRecording ? AnyShapeStyle(Self.recordGradient) : AnyShapeStyle(Self.brand))
                            .frame(width: 128, height: 128)
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .shadow(color: (coordinator.isRecording ? Color(red: 0.95, green: 0.25, blue: 0.4) : Color(red: 0.42, green: 0.45, blue: 0.98)).opacity(0.5), radius: 24, y: 12)
                        Image(systemName: coordinator.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .scaleEffect(coordinator.isRecording ? 1.03 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: coordinator.isRecording)
            }
            .frame(height: 168)

            Text(coordinator.isRecording
                 ? "Recording… tap to stop"
                 : "Tap to start  ·  or hold \(coordinator.settings.hotkey.displayString)")
                .font(.callout.weight(.medium))
                .foregroundStyle(coordinator.isRecording ? Color(red: 0.9, green: 0.25, blue: 0.4) : .secondary)
        }
    }

    // MARK: - Status + last result

    @ViewBuilder private var statusBlock: some View {
        if let result = coordinator.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: result.outcome.didInsert ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        .foregroundStyle(result.outcome.didInsert ? .green : .orange)
                    Text(result.outcome.didInsert ? "Inserted into \(result.record.appName ?? "app")" : "Copied to clipboard")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(result.record.mode.displayName).font(.caption2).foregroundStyle(.secondary)
                }
                Text(result.record.cleanText)
                    .font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text(coordinator.statusText).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: modeBinding) {
            ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var modeBinding: Binding<DictationMode> {
        Binding(get: { coordinator.settings.defaultMode },
                set: { var s = coordinator.settings; s.defaultMode = $0; coordinator.applySettings(s) })
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").font(.headline)
                if coordinator.stats.sampleCount > 0 {
                    Text(statsSummary)
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Median time from releasing the key to text appearing, and how often you left the text untouched — measured on your own dictations, stored only on this Mac.")
                }
                Spacer()
                if !coordinator.recentRecords.isEmpty {
                    Button("Clear") { coordinator.clearHistory() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.recentRecords.isEmpty {
                Text("Nothing yet. Hold the button and say something.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(coordinator.recentRecords) { record in
                            HistoryCard(record: record,
                                        onCopy: { coordinator.copyRecord(record) },
                                        onDelete: { coordinator.deleteHistory(record.id) })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statsSummary: String {
        let stats = coordinator.stats
        let latency = stats.medianInsertLatency > 0
            ? String(format: "%.1fs median", stats.medianInsertLatency) : "—"
        return "\(latency)  ·  \(Int((stats.zeroEditRate * 100).rounded()))% unedited  (\(stats.sampleCount))"
    }

    private var background: some View {
        LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                Color(red: 0.36, green: 0.42, blue: 0.98).opacity(0.06)],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

private struct HistoryCard: View {
    let record: TranscriptRecord
    let onCopy: () -> Void
    let onDelete: () -> Void

    /// The verbatim transcript, shown only when cleanup actually changed
    /// something — so any word cleanup added, dropped or swapped is visible
    /// rather than taking the user's word for it.
    private var rawDiffers: Bool {
        record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            != record.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.cleanText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)   // show the FULL script, wrapping
                    .frame(maxWidth: .infinity, alignment: .leading)
                if rawDiffers {
                    HStack(alignment: .top, spacing: 5) {
                        Text("heard").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        Text(record.rawText)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Label(record.appName ?? "Unknown", systemImage: "app.dashed")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(record.mode.displayName).font(.caption2).foregroundStyle(.tertiary)
                    // Release-to-insert is the number that describes the feel;
                    // fall back to the older total for pre-Phase-2 records.
                    Text(record.insertLatencySeconds > 0
                         ? String(format: "%.1fs to insert", record.insertLatencySeconds)
                         : String(format: "%.1fs", record.latencySeconds))
                        .font(.caption2).foregroundStyle(.tertiary)
                    // The itemized bill: where those seconds actually went.
                    if record.transcribeSeconds > 0 {
                        Text(Self.stageBreakdown(record))
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    if record.editedAfterInsert {
                        Label("edited", systemImage: "pencil")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    /// "1.4s whisper + 0.9s check + 0.3s polish" — the per-stage bill, shown only
    /// for the stages that actually cost something. "check" is the second-opinion
    /// engine (part of the transcribe time, broken out because it is the variable
    /// cost); "polish" is the cleanup pipeline.
    static func stageBreakdown(_ record: TranscriptRecord) -> String {
        var parts: [String] = []
        let decode = max(0, record.transcribeSeconds - record.arbiterSeconds)
        parts.append(String(format: "%.1fs %@", decode, record.engineUsed ?? "decode"))
        if record.arbiterSeconds > 0.05 {
            parts.append(String(format: "%.1fs check", record.arbiterSeconds))
        }
        if record.cleanupSeconds > 0.05 {
            parts.append(String(format: "%.1fs polish", record.cleanupSeconds))
        }
        return parts.joined(separator: " + ")
    }
}
