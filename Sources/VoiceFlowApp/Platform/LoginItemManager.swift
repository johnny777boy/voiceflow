import Foundation
import ServiceManagement
import VoiceFlowCore

/// Registers/unregisters the app as a login item using the modern
/// `SMAppService` API (macOS 13+). Best-effort: failures are logged, never fatal.
enum LoginItemManager {
    /// Reconcile the login-item registration with the desired state.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            Log.controller.info("Login item set to \(enabled, privacy: .public)")
        } catch {
            Log.controller.error("Login item update failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
