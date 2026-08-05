import Foundation
import AppKit
import SwiftUI
import VoiceFlowCore

/// Live model backing the floating pill. Updating `level` animates the waveform
/// without rebuilding the hosting view.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: OverlayController.State = .recording
    @Published var level: CGFloat = 0
}

/// A small floating pill near the bottom of the screen — a Wispr-style live
/// waveform while recording, then a brief status. Borderless, non-activating
/// NSPanel so it never steals focus from the app you're dictating into.
@MainActor
final class OverlayController {
    enum State: Equatable {
        case recording
        case processing
        case done(DictationResult)
        case error(String)
    }

    let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(state: State) {
        model.state = state
        if state == .recording { model.level = 0 }
        let panel = ensurePanel()
        positionBottomCenter(panel)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        switch state {
        case .recording, .processing:
            break
        case .done, .error:
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    /// Push a fresh mic level (0…1) into the live waveform.
    func updateLevel(_ level: Float) {
        model.level = CGFloat(max(0, min(1, level)))
    }

    func hide() {
        model.level = 0
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 168, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 168, height: 44)
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
