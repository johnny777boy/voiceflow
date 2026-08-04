import Foundation
import OSLog

/// Centralized OSLog categories so subsystems log consistently and privately.
public enum Log {
    public static let subsystem = "com.voiceflow.dictation"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    public static let insertion = Logger(subsystem: subsystem, category: "insertion")
    public static let destination = Logger(subsystem: subsystem, category: "destination")
    public static let history = Logger(subsystem: subsystem, category: "history")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let controller = Logger(subsystem: subsystem, category: "controller")
}
