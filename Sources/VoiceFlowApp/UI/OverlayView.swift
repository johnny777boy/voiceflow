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
        HStack(spacing: 11) {
            leading
            if let titleText {
                Text(titleText)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(pillBackground)
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .frame(width: 280, height: 56)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: titleText)
    }

    private var pillBackground: some View {
        ZStack {
            Capsule().fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.92))
            // Soft accent glow while recording.
            if isRecording {
                Capsule().fill(Self.accent).opacity(0.14 + 0.12 * Double(model.level))
                    .blur(radius: 8)
            }
        }
    }

    private var isRecording: Bool { if case .recording = model.state { return true }; return false }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .recording:
            WaveformBars(level: model.level, gradient: Self.accent)
                .frame(width: 130, height: 26)
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
    private let count = 21

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(gradient)
                        .frame(width: 2.5, height: height(i, t))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let minH: CGFloat = 2.5
        let maxH: CGFloat = 26
        // Smooth level with a floor so it always breathes a little.
        let energy = 0.12 + 0.88 * min(1, max(0, level))
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
