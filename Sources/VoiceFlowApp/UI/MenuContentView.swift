import SwiftUI
import VoiceFlowCore

/// The menu-bar popover: status, quick actions, and recent history.
struct MenuContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            permissionBanner
            recentSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: coordinator.isRecording ? "mic.fill" : "waveform")
                .foregroundStyle(coordinator.isRecording ? .red : .accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("VoiceFlow").font(.headline)
                Text(coordinator.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(coordinator.settings.hotkey.displayString)
                .font(.caption.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder private var permissionBanner: some View {
        if !coordinator.accessibilityGranted {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                Text("Grant Accessibility permission to enable the hotkey and text insertion.")
                    .font(.caption)
            }
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.subheadline.weight(.semibold))
                Spacer()
                if !coordinator.recentRecords.isEmpty {
                    Button("Clear") { coordinator.clearHistory() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.recentRecords.isEmpty {
                Text("No dictations yet. Hold \(coordinator.settings.hotkey.displayString) to talk.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.recentRecords.prefix(5)) { record in
                    HistoryRow(record: record,
                               onCopy: { coordinator.copyRecord(record) },
                               onDelete: { coordinator.deleteHistory(record.id) })
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.callout)
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.cleanText).font(.caption).lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.appName ?? "Unknown").font(.caption2).foregroundStyle(.secondary)
                    Text(record.mode.displayName).font(.caption2).foregroundStyle(.tertiary)
                    Text(String(format: "%.1fs", record.latencySeconds)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
