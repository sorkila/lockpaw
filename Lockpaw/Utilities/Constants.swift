import SwiftUI

enum Constants {
    static let appName = "Lockpaw"
    static let bundleIdentifier = "com.eriknielsen.lockpaw"
    static let urlScheme = "lockpaw"
    static let defaultLockMessage = "Agents are working. Don't turn me off."

    /// Distributed notification name the `lockpaw` CLI posts on `ping`.
    /// DistributedNotificationCenter is used (not the URL scheme) so a background
    /// ping never launches the app when it isn't already running.
    static let pingDistributedName = "com.eriknielsen.lockpaw.ping"

    /// UserDefaults key: play a sound on agent ping. Off by default for shared spaces.
    static let agentPingSoundKey = "agentPingSound"

    enum Timing {
        static let inputBlockerDelayNs: UInt64 = 50_000_000           // 50ms
        static let unlockSuccessAnimNs: UInt64 = 400_000_000          // 400ms
        static let errorDisplayBeforeForceUnlockNs: UInt64 = 1_500_000_000 // 1.5s
        static let errorAutoClearNs: UInt64 = 5_000_000_000           // 5s
        static let authRateLimitCooldown: TimeInterval = 30.0         // seconds
        static let maxAuthAttempts = 3
        static let urlSchemeDebounce: TimeInterval = 0.1              // seconds
        static let userActivityRefreshInterval: TimeInterval = 30     // seconds; defeats screensaver idle timer while locked
        static let pingDebounce: TimeInterval = 2.0                   // seconds; collapse chatty agent pings into one
        static let pingPulseCount = 2                                 // breaths per agent ping
        static let pingPulsePeriod: TimeInterval = 2.2                // seconds per full breath (rise + fall)
        static let pingPulseFloor: CGFloat = 0.30                     // glow level between breaths (never fully dark mid-pulse)
        static let pingGlowRest: CGFloat = 0.08                       // faint glow held after the breaths until unlock — paired with the "agent needs you" hint
        static let cursorIdleHide: TimeInterval = 3.0                 // seconds of stillness before the pointer hides again while locked
        static let agentSetupMinSpin: TimeInterval = 1.2              // seconds; floor on the Settings connect-spinner so success registers
    }

    enum Anim {
        // Canonical curves — shared with the website (see DESIGN.md §4).
        // ease-out (expressive): cubic-bezier(0.16, 1, 0.3, 1) — entrances & reveals.
        static let quick: Animation = .easeOut(duration: 0.2)
        static let standard: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
        static let gentle: Animation = .easeInOut(duration: 0.5)
        static let entrance: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.8)
        static let spring: Animation = .spring(response: 0.4, dampingFraction: 0.75)
        /// Monotonic breathing phase driving every sine/cosine oscillator in the lock
        /// and ambient screens. Advances at 1 phase-unit per 12s over a ~14-day span so
        /// the oscillators never hit the 0→1 wrap that used to snap the mascot every 12s.
        /// Animate `phase` to `breathePhaseTarget` (not 1) with this curve.
        static let breathePhaseTarget: CGFloat = 100_000
        static let breathe: Animation = .linear(duration: 12 * Double(breathePhaseTarget)).repeatForever(autoreverses: false)
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

/// Lock-screen type roles — the four rows of the DESIGN.md §2 scale. Every piece of
/// text on the lock screen uses one of these; differentiate with opacity, not size.
/// Tracking pairs: body 0.35, label 0.3, caption/mono 0.5.
extension Font {
    static func lockBody(compact: Bool) -> Font { .system(size: compact ? 14 : 16, weight: .regular) }
    static let lockLabel: Font = .system(size: 13, weight: .medium)
    static let lockCaption: Font = .system(size: 12, weight: .light)
    static let lockMono: Font = .system(size: 12, weight: .regular, design: .monospaced)
}
