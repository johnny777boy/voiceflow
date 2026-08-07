import SwiftUI
import VoiceFlowCore

/// Preferences window. Edits a local draft of `AppSettings` and applies changes
/// back to the coordinator (which persists them and reconfigures the controller).
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var draft: AppSettings
    @State private var apiKey: String = ""
    @AppStorage("useWhisperEngine") private var useWhisper = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _draft = State(initialValue: coordinator.settings)
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            modes.tabItem { Label("Modes & Apps", systemImage: "app.badge") }
            vocabulary.tabItem { Label("Vocabulary", systemImage: "textformat") }
            privacy.tabItem { Label("Privacy & AI", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 420)
        .onChange(of: draft) { _, newValue in coordinator.applySettings(newValue) }
        .onAppear { apiKey = coordinator.hasAPIKey() ? "••••••••" : "" }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Picker("Default mode", selection: $draft.defaultMode) {
                ForEach(DictationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Cleanup strength", selection: $draft.cleanupStrength) {
                ForEach(CleanupStrength.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Language (BCP-47)", text: $draft.languageCode)
            LabeledContent("Push-to-talk hotkey", value: draft.hotkey.displayString)
            Toggle("Show recording overlay", isOn: $draft.overlayEnabled)
            Toggle("Launch at login", isOn: $draft.launchAtLogin)
        }
        .formStyle(.grouped).padding()
    }

    // MARK: - Modes & per-app

    private var modes: some View {
        VStack(alignment: .leading) {
            Text("Per-app default mode").font(.headline)
            Table(draft.perAppBehaviors) {
                TableColumn("App") { Text($0.appName) }
                TableColumn("Bundle ID") { Text($0.bundleIdentifier).font(.caption.monospaced()) }
                TableColumn("Mode") { Text($0.defaultMode.displayName) }
                TableColumn("Copy-only") { Text($0.forceCopyOnly ? "Yes" : "No") }
            }
        }
        .padding()
    }

    // MARK: - Vocabulary

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spoken → written replacements").font(.headline)
            Table(draft.vocabulary) {
                TableColumn("Spoken") { Text($0.spoken) }
                TableColumn("Written") { Text($0.written) }
                TableColumn("Enabled") { Text($0.isEnabled ? "✓" : "") }
            }
            HStack {
                Button("Add example") {
                    draft.vocabulary.append(VocabularyEntry(spoken: "spoken form", written: "Written Form"))
                }
                Button("Reset to defaults") { draft.vocabulary = VocabularyEntry.defaults }
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Privacy & AI

    private var privacy: some View {
        Form {
            Toggle("High Accuracy transcription (on-device Whisper)", isOn: $useWhisper)
                .onChange(of: useWhisper) { _, on in
                    coordinator.whisperManager.setEnabled(on)
                }
            WhisperStatusRow(manager: coordinator.whisperManager)
            Text("Uses on-device Whisper instead of Apple's engine — noticeably better for accents/non-native English, ~1–2s slower. Turning it on downloads the model (~1 GB) in the background; dictation keeps working on Apple's engine and switches to Whisper automatically when it's ready. Audio never leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Use AI cleanup (requires API key)", isOn: $draft.useLLMCleanup)
            SecureField("Anthropic API key", text: $apiKey)
                .onSubmit { if apiKey != "••••••••" { coordinator.setAPIKey(apiKey) } }
            Text("Stored in the macOS Keychain. Without a key, cleanup uses the built-in offline engine.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Keep history", isOn: $draft.historyEnabled)
            Stepper("Keep last \(draft.historyRetentionLimit) dictations",
                    value: $draft.historyRetentionLimit, in: 0...5000, step: 50)
            Toggle("Redact private transcripts", isOn: $draft.privacyRedactionEnabled)
        }
        .formStyle(.grouped).padding()
    }
}

/// Live status line for the Whisper model: download progress bar, preparing
/// spinner, ready check, or failure + Retry. Hidden while idle.
private struct WhisperStatusRow: View {
    @ObservedObject var manager: WhisperModelManager

    var body: some View {
        switch manager.state {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading Whisper model… \(Int(fraction * 100))%  (dictation keeps using Apple's engine)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing model — first time can take a few minutes…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Whisper is ready — dictations now use High Accuracy.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { manager.retry() }
            }
        }
    }
}
