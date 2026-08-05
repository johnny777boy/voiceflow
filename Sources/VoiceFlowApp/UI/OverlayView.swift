import SwiftUI
import VoiceFlowCore

/// The floating pill's content. A live waveform while recording; a compact
/// status while transcribing / after inserting.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            label
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .frame(width: 260, height: 52)
        .animation(.easeInOut(duration: 0.2), value: label2)
    }

    // A tiny value used only to trigger the label crossfade.
    private var label2: String { titleText ?? "wave" }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                WaveformBars(level: model.level)
                    .frame(width: 96, height: 22)
            }
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .done(let r):
            Image(systemName: r.outcome.didInsert ? "checkmark.circle.fill" : "text.cursor")
                .foregroundStyle(r.outcome.didInsert ? Color.green : Color.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    @ViewBuilder private var label: some View {
        if let titleText {
            Text(titleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var titleText: String? {
        switch model.state {
        case .recording:  return nil            // the waveform speaks for itself
        case .processing: return "Transcribing…"
        case .done(let r): return r.outcome.didInsert ? "Inserted" : "No text box — click one first"
        case .error:      return "Try again"
        }
    }
}

/// A row of bars that pulse with the mic level — the "vibration" you see while
/// speaking. Driven by a timeline so it animates continuously; amplitude follows
/// the live level.
private struct WaveformBars: View {
    var level: CGFloat
    private let count = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 3, height: height(i, t))
                }
            }
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let base: CGFloat = 3
        let amp = 19 * max(0.06, level)                 // idle shimmer + speech amplitude
        // Center bars taller than the edges, each with its own phase.
        let center = CGFloat(count - 1) / 2
        let falloff = 1 - abs(CGFloat(i) - center) / (center + 1) * 0.55
        let phase = t * 9 + Double(i) * 0.6
        let wave = (sin(phase) * 0.5 + 0.5)
        return base + amp * falloff * CGFloat(wave)
    }
}
