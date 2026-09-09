import Foundation
import LocalAuthentication

/// Outcome of a passive (no visible prompt) Touch ID evaluation, reduced to the two
/// facts the policy needs. `Sendable` so it can cross the `Task.detached` boundary
/// LAContext evaluation runs on.
struct PassiveAuthResult: Sendable, Equatable {
    let authenticated: Bool
    let errorCode: LAError.Code?

    static let success = PassiveAuthResult(authenticated: true, errorCode: nil)

    static func failure(_ code: LAError.Code) -> PassiveAuthResult {
        PassiveAuthResult(authenticated: false, errorCode: code)
    }
}

/// What a finished passive evaluation feeds back into the lock.
enum PassiveAuthOutcome: Equatable {
    case unlock

    /// A finger the sensor rejected. Getting here took a physical touch, so re-arming
    /// straight away cannot spin.
    case rearmImmediately

    /// Cancelled or expired with no touch involved. Re-arm from the lock tick instead —
    /// an ending that can repeat without user input would spin if it re-armed itself.
    case rearmOnNextTick

    /// Stable for the rest of this lock session: no usable biometry, hardware lockout, or
    /// the prompt was dismissed. Leave the sensor cold; the button path is untouched.
    case standDown
}

/// Pure rules for the armed Touch ID path, free of UI and LAContext so both the arming
/// guard and the outcome mapping can be unit-tested directly.
enum PassiveAuthPolicy {

    /// `unlockCommitted` is the success animation: the state machine is still `.locked`
    /// while it plays, so without this a re-arm landing in that window would invalidate the
    /// evaluation that had *just* succeeded and swallow the unlock it was animating.
    static func shouldArm(
        state: LockState,
        unlockCommitted: Bool,
        biometryAvailable: Bool,
        suspended: Bool,
        authenticationInProgress: Bool,
        failCount: Int,
        lastFailure: Date?,
        now: Date,
        cooldown: TimeInterval = Constants.Timing.authRateLimitCooldown,
        maxAttempts: Int = Constants.Timing.maxAuthAttempts
    ) -> Bool {
        guard state == .locked, !unlockCommitted, biometryAvailable,
              !suspended, !authenticationInProgress else { return false }

        // The 30s cooldown belongs to the paths the user actually initiated. Arming
        // respects it — the sensor stays cold while it runs — but never feeds it.
        guard failCount >= maxAttempts, let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= cooldown
    }

    static func outcome(_ result: PassiveAuthResult) -> PassiveAuthOutcome {
        if result.authenticated { return .unlock }

        switch result.errorCode {
        case .authenticationFailed:
            // Nobody asked for this: a palm or a bag strap resting on the sensor reads
            // exactly like a wrong finger. So it must not spend the button path's three
            // attempts, and must not paint "Too many attempts" on an unattended lock
            // screen. Touch ID enforces its own lockout in hardware, and that arrives
            // below as .biometryLockout — the OS is the rate limiter here.
            return .rearmImmediately

        // Stable conditions that cannot fix themselves while this lock session runs.
        // (The deprecated .touchID* codes share raw values with their .biometry* twins,
        // so listing these covers both spellings.)
        case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled,
             .passcodeNotSet, .userCancel, .userFallback:
            return .standDown

        default:
            // Fail open. An unrecognised ending — a future error code, an evaluation the
            // system expired after hours armed, a Touch ID keyboard unplugged and plugged
            // back in — should recover rather than leave the sensor cold for the session.
            // Tick-gated re-arming is what makes that safe.
            return .rearmOnNextTick
        }
    }
}
