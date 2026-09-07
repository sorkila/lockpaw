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

/// Whether the Touch ID sensor should be armed right now.
enum PassiveArmDecision: Equatable {
    case arm
    /// Rate-limited. Arm again once the cooldown has this much left to run.
    case armAfter(TimeInterval)
    /// Nothing to arm: not covered, no usable biometry, or a visible prompt already
    /// owns the single LAContext slot.
    case doNotArm
}

/// What a finished passive evaluation feeds back into the lock.
enum PassiveAuthOutcome: Equatable {
    case unlock
    /// A finger the sensor saw and rejected — counts toward the rate limit, then re-arms.
    case countFailureAndRearm
    /// Cancelled by us, taken over by the system, or biometry became unusable. Leave the
    /// sensor cold; the explicit "Authenticate" button is still there.
    case standDown
}

/// Pure rules for the always-armed Touch ID path, free of UI and LAContext so both the
/// arming guard and the outcome mapping can be unit-tested directly.
enum PassiveAuthPolicy {

    static func decide(
        state: LockState,
        biometryAvailable: Bool,
        authenticationInProgress: Bool,
        failCount: Int,
        lastFailure: Date?,
        now: Date,
        cooldown: TimeInterval = Constants.Timing.authRateLimitCooldown,
        maxAttempts: Int = Constants.Timing.maxAuthAttempts
    ) -> PassiveArmDecision {
        guard state == .locked, biometryAvailable, !authenticationInProgress else { return .doNotArm }
        guard failCount >= maxAttempts, let lastFailure else { return .arm }

        let elapsed = now.timeIntervalSince(lastFailure)
        guard elapsed < cooldown else { return .arm }
        return .armAfter(cooldown - elapsed)
    }

    /// Only a finger the sensor rejected is the user's failure. Everything else — our own
    /// invalidate when the button path takes over, a system takeover on session switch,
    /// biometry that vanished — would otherwise burn the three-attempt budget without
    /// anyone having touched the Mac.
    static func outcome(_ result: PassiveAuthResult) -> PassiveAuthOutcome {
        if result.authenticated { return .unlock }
        return result.errorCode == .authenticationFailed ? .countFailureAndRearm : .standDown
    }
}
