import SwiftUI
import AppKit
import VoiceFlowCore

/// A control that captures a new global hotkey. Click it, then press the key
/// combo you want; it builds a `HotkeyConfiguration` and reports it via `onCommit`.
struct HotkeyRecorderView: View {
    let current: HotkeyConfiguration
    let onCommit: (HotkeyConfiguration) -> Void

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: capturing ? "record.circle" : "keyboard")
                    .font(.caption2)
                    .foregroundStyle(capturing ? .red : .secondary)
                Text(capturing ? "Press keys…" : current.displayString)
                    .font(.caption.monospaced().weight(.medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(capturing ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Click, then press a key combo to set the push-to-talk shortcut")
        .onDisappear(perform: stop)
    }

    private func toggle() { capturing ? stop() : start() }

    private func start() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Ignore lone modifier presses; wait for an actual key.
            guard let config = Self.configuration(from: event, isPushToTalk: current.isPushToTalk) else {
                return nil
            }
            onCommit(config)
            stop()
            return nil   // swallow the key so it doesn't type
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }

    // MARK: - Event → HotkeyConfiguration

    static func configuration(from event: NSEvent, isPushToTalk: Bool) -> HotkeyConfiguration? {
        var mask: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mask |= HotkeyMatcher.carbonCommand }
        if flags.contains(.shift)   { mask |= HotkeyMatcher.carbonShift }
        if flags.contains(.option)  { mask |= HotkeyMatcher.carbonOption }
        if flags.contains(.control) { mask |= HotkeyMatcher.carbonControl }

        let keyCode = UInt32(event.keyCode)
        let display = displayString(keyCode: event.keyCode, flags: flags, event: event)
        return HotkeyConfiguration(keyCode: keyCode, modifierFlags: mask, displayString: display, isPushToTalk: isPushToTalk)
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 117: "Fwd-Del",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static func displayString(keyCode: UInt16, flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        if let name = specialKeys[keyCode] {
            s += name
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty, chars != " " {
            s += chars.uppercased()
        } else {
            s += "Key\(keyCode)"
        }
        return s
    }
}
