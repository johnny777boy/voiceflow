import Foundation
import AppKit
import SwiftUI
import VoiceFlowCore

/// A small floating overlay shown near the bottom of the screen while recording
/// and processing. Backed by a borderless, non-activating NSPanel.
@MainActor
final class OverlayController {
    enum State: Equatable {
        case recording
        case processing
        case done(DictationResult)
        case error(String)
    }

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(state: State) {
        let view = OverlayView(state: state)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 64)

        let panel = existingPanel()
        panel.contentView = hosting
        positionBottomCenter(panel)
        panel.orderFrontRegardless()

        // Auto-hide terminal states.
        hideWorkItem?.cancel()
        switch state {
        case .recording, .processing:
            break
        case .done, .error:
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
