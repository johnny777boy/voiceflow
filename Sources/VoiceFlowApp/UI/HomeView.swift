import SwiftUI
import VoiceFlowCore

/// The main app window. A visible, mouse-usable surface for dictation: hold the
/// big button (or the global hotkey) to talk, switch modes, and see history.
struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings
    @State private var pressing = false

    private static let brand = LinearGradient(
        colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.58, green: 0.30, blue: 0.92)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        VStack(spacing: 18) {
            header
            if !coordinator.accessibilityGranted { permissionBanner }
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
            Text(coordinator.settings.hotkey.displayString)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
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

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("Grant **Accessibility** in System Settings to enable the hotkey and text insertion.")
                .font(.caption)
            Spacer(minLength: 0)
            Button("Open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.font(.caption)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Talk button (hold to talk)

    private var talkButton: some View {
        VStack(spacing: 12) {
            ZStack {
                // Pulsing rings while recording.
                if coordinator.isRecording {
                    Circle().stroke(Color.red.opacity(0.35), lineWidth: 3)
                        .scaleEffect(pressing || coordinator.isRecording ? 1.25 : 1)
                        .opacity(0.0)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: coordinator.isRecording)
                    Circle().stroke(Color.red.opacity(0.25), lineWidth: 2)
                        .scaleEffect(1.12)
                }
                Circle()
                    .fill(coordinator.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(Self.brand))
                    .frame(width: 132, height: 132)
                    .shadow(color: (coordinator.isRecording ? Color.red : Color.blue).opacity(0.35), radius: 18, y: 8)
                    .scaleEffect(pressing ? 0.94 : 1)
                Image(systemName: coordinator.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: coordinator.isRecording)
            }
            .frame(height: 160)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing { pressing = true; coordinator.beginRecording() }
                    }
                    .onEnded { _ in
                        pressing = false; coordinator.finishRecording()
                    }
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressing)

            Text(coordinator.isRecording ? "Listening… release to insert" : "Hold to talk  ·  or press \(coordinator.settings.hotkey.displayString)")
                .font(.callout).foregroundStyle(.secondary)
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
                Text(result.record.cleanText).font(.callout).textSelection(.enabled).lineLimit(4)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.cleanText).font(.callout).lineLimit(3)
                HStack(spacing: 8) {
                    Label(record.appName ?? "Unknown", systemImage: "app.dashed")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(record.mode.displayName).font(.caption2).foregroundStyle(.tertiary)
                    Text(String(format: "%.1fs", record.latencySeconds)).font(.caption2).foregroundStyle(.tertiary)
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
}
