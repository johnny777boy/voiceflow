import SwiftUI
import VoiceFlowCore

@main
struct VoiceFlowApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.isRecording ? "mic.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }

    init() {
        // `start()` must run on the main actor after the coordinator exists.
        let coordinator = _coordinator.wrappedValue
        Task { @MainActor in coordinator.start() }
    }
}
