import SwiftUI
import VoiceFlowCore

/// The floating pill's content — a modern, Wispr-style capsule: a smooth mirrored
/// waveform that pulses with your voice while recording, then a compact status.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    // Brand gradient (matches the app icon / talk button).
    private static let accent = LinearGradient(
        colors: [Color(red: 0.42, green: 0.51, blue: 1.0), Color(red: 0.63, green: 0.34, blue: 0.97)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        HStack(spacing: 8) {
            leading
            if let titleText {
                Text(titleText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(pillBackground)
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .fixedSize()
        .frame(width: 168, height: 44)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: titleText)
    }

    // One clean, solid capsule — no glow layer behind it.
    private var pillBackground: some View {
        Capsule().fill(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .recording:
            WaveformBars(level: model.level, gradient: Self.accent)
                .frame(width: 82, height: 16)
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                EmptyView()
            }
        case .done(let r):
            Image(systemName: r.outcome.didInsert ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(r.outcome.didInsert ? Color(red: 0.35, green: 0.85, blue: 0.5) : .orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.yellow)
        }
    }

    private var titleText: String? {
        switch model.state {
        case .recording:  return nil            // the waveform speaks for itself
        case .processing: return "Transcribing…"
        case .done(let r): return r.outcome.didInsert ? "Inserted" : "Copied to clipboard"
        case .error:      return "Try again"
        }
    }
}

/// A smooth, mirrored waveform. Bars grow symmetrically from the centre line with
/// their own phase, and the amplitude tracks the live mic level — an idle shimmer
/// when quiet, taller peaks when you speak.
private struct WaveformBars: View {
    var level: CGFloat
    var gradient: LinearGradient
    private let count = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(gradient)
                        .frame(width: 2, height: height(i, t))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let minH: CGFloat = 2
        let maxH: CGFloat = 16
        // Idle floor so the bars always visibly flow; amplitude grows with voice.
        let energy = 0.34 + 0.66 * min(1, max(0, level))
        // Bell-shaped envelope: centre bars taller than the edges.
        let center = CGFloat(count - 1) / 2
        let dist = abs(CGFloat(i) - center) / center           // 0 at centre, 1 at edges
        let envelope = pow(1 - dist, 1.4)
        // Two travelling sine waves for an organic, non-uniform motion.
        let phase = t * 7.5 + Double(i) * 0.55
        let wave = 0.55 + 0.45 * sin(phase) * (0.7 + 0.3 * sin(t * 3.1 + Double(i) * 0.2))
        let h = minH + (maxH - minH) * envelope * energy * CGFloat(wave)
        return max(minH, h)
    }
}
