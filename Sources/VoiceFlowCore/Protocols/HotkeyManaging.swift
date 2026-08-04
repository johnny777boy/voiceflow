import Foundation

/// Events emitted by the global hotkey layer.
public enum HotkeyEvent: Sendable, Equatable {
    /// The push-to-talk chord was pressed (begin recording).
    case pressed
    /// The push-to-talk chord was released (stop recording).
    case released
    /// A toggle-style hotkey fired once.
    case toggled
}

/// Abstraction over global (system-wide) hotkey registration.
public protocol HotkeyManaging: AnyObject, Sendable {
    /// Install the given hotkey and route events to `handler`.
    func register(_ configuration: HotkeyConfiguration, handler: @escaping @Sendable (HotkeyEvent) -> Void)
    /// Remove the currently registered hotkey.
    func unregister()
}
