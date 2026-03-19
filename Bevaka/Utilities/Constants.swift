import SwiftUI

enum Constants {
    static let appName = "Bevaka"
    static let bundleIdentifier = "com.eriknielsen.bevaka"
    static let urlScheme = "bevaka"
    static let defaultLockMessage = "Agents are working. Don't turn me off."

    enum Anim {
        static let quick: Animation = .easeOut(duration: 0.2)
        static let standard: Animation = .easeOut(duration: 0.35)
        static let gentle: Animation = .easeInOut(duration: 0.5)
        static let entrance: Animation = .easeOut(duration: 0.8)
        static let spring: Animation = .spring(response: 0.4, dampingFraction: 0.75)
        static let breathe: Animation = .linear(duration: 12).repeatForever(autoreverses: false)
    }

    static func formatElapsedTime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return String(format: "%ds", seconds)
    }

    static func formatElapsedTimeAccessible(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) minute\(minutes == 1 ? "" : "s")" }
        if minutes > 0 { return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")" }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
