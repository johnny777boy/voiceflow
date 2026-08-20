import Foundation

/// A developer switch that defaults ON unless explicitly turned off.
///
/// `UserDefaults.object(forKey:) as? Bool` looks like the obvious way to express
/// "true unless someone said otherwise", and it is wrong in the one place these
/// switches matter most: a command-line override (`-flag NO`) arrives through
/// NSArgumentDomain as the STRING "NO", the cast to Bool fails, and the switch
/// silently reads as its default.
///
/// That cost a real experiment on 2026-08-20 — a chunking A/B where both arms
/// ran with chunking ON and reported byte-identical output, which reads exactly
/// like "this setting does nothing".
public enum DevSwitch {
    /// True unless the key is present and explicitly false, whether it was
    /// written as a real Bool (`defaults write -bool NO`) or as an argument
    /// string (`-key NO`).
    public static func isOn(_ key: String, default defaultValue: Bool = true) -> Bool {
        guard let raw = UserDefaults.standard.object(forKey: key) else { return defaultValue }
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "no", "false", "0", "off": return false
            case "yes", "true", "1", "on": return true
            default: return defaultValue
            }
        }
        return defaultValue
    }
}
