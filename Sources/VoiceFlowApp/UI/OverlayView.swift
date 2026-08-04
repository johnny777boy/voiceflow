import SwiftUI
import VoiceFlowCore

/// The content of the floating overlay for each state.
struct OverlayView: View {
    let state: OverlayController.State

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .recording: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .processing: ProgressView().controlSize(.small)
        case .done(let r): Image(systemName: r.outcome.didInsert ? "checkmark.circle.fill" : "doc.on.clipboard")
                .foregroundStyle(r.outcome.didInsert ? .green : .orange)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    private var title: String {
        switch state {
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        case .done(let r): return r.outcome.didInsert ? "Inserted" : "Copied to clipboard"
        case .error: return "Something went wrong"
        }
    }

    private var subtitle: String? {
        switch state {
        case .recording: return "Release the hotkey to finish"
        case .processing: return nil
        case .done(let r): return r.record.cleanText
        case .error(let message): return message
        }
    }
}
