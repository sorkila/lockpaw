import Foundation

/// When lid-closed mode may hold system sleep off. Pure, so the safety cutouts are unit-tested.
///
/// Only while locked: lid-closed mode is "close the lid, walk away, the agents keep running,
/// open it to the lock screen" — not a general keep-awake toggle. And never against the
/// machine's own interest: a hot Mac in a closed bag, or a battery about to run flat, sleeps.
enum LidSleepPolicy {
    /// At or below this on battery, sleep is allowed again.
    static let batteryFloor = 20
    /// Hysteresis: once cut off for battery, blocking resumes only at this level (or on AC),
    /// so a reading wobbling around the floor can't flap pmset.
    static let batteryResume = 25

    struct Power: Equatable {
        var onBattery: Bool
        /// nil when there is no battery (desktop Macs) or it can't be read.
        var batteryPercent: Int?
    }

    enum Thermal: Equatable {
        case nominal, fair, serious, critical

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }
    }

    struct Decision: Equatable {
        var block: Bool
        /// Carried into the next evaluation for the battery hysteresis.
        var cutOffForBattery: Bool
    }

    static func decide(
        enabled: Bool,
        helperReady: Bool,
        locked: Bool,
        power: Power,
        thermal: Thermal,
        cutOffForBattery: Bool
    ) -> Decision {
        let cutOff: Bool
        if !power.onBattery {
            cutOff = false
        } else if let percent = power.batteryPercent {
            cutOff = cutOffForBattery ? percent < batteryResume : percent <= batteryFloor
        } else {
            cutOff = cutOffForBattery
        }
        let hot = thermal == .serious || thermal == .critical
        return Decision(block: enabled && helperReady && locked && !cutOff && !hot, cutOffForBattery: cutOff)
    }
}

/// How Lockpaw relates to the macOS lock screen. Pure, so the unlock path it opens is tested.
enum SystemLockPolicy {
    /// After the user unlocks macOS itself (typically opening the lid with "require password"
    /// on), whether Lockpaw also comes down. Off by default — Lockpaw never unlocks because of
    /// something outside it unless asked to. Safe when on: the macOS unlock is at least as
    /// strong as Lockpaw's own, only a macOS lock that began during this Lockpaw lock counts,
    /// and both ends are confirmed with the window server (`sessionReportsLocked` false now,
    /// true when the lock was seen) — the notifications alone can be posted by any process.
    static func unlocksAfterSystemUnlock(
        state: LockState, systemLockSeenDuringLock: Bool, sessionReportsLocked: Bool, settingEnabled: Bool
    ) -> Bool {
        settingEnabled && state == .locked && systemLockSeenDuringLock && !sessionReportsLocked
    }

    /// While the macOS session is locked, Accessibility can read as revoked — the session's
    /// event taps die with it. That is not a revocation, so it must not trip the force-unlock
    /// that a real one gets; the taps are reinstalled when macOS unlocks.
    static func forceUnlocksForAccessibility(trusted: Bool, systemScreenLocked: Bool) -> Bool {
        !trusted && !systemScreenLocked
    }
}
