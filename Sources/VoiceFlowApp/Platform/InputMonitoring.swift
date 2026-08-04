import Foundation
import IOKit.hid

/// A global CGEvent keyboard tap requires **Input Monitoring** permission on
/// macOS 10.15+ (in addition to Accessibility for an active/consuming tap).
enum InputMonitoring {
    static func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompts for Input Monitoring if not yet determined. Returns whether granted.
    @discardableResult
    static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
