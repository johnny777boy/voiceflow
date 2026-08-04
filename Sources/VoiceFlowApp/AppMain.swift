import SwiftUI
import VoiceFlowCore

@main
struct VoiceFlowApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        // Main window: a visible, Dock-present surface.
        Window("VoiceFlow", id: "main") {
            HomeView(coordinator: coordinator)
        }
        .defaultSize(width: 440, height: 660)
        .windowResizability(.contentMinSize)

        // Menu-bar extra: quick access + the same history without opening the window.
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
