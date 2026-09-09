import XCTest
import LocalAuthentication
@testable import Lockpaw

final class PassiveAuthTests: XCTestCase {

    private let cooldown = Constants.Timing.authRateLimitCooldown
    private let maxAttempts = Constants.Timing.maxAuthAttempts
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func shouldArm(
        state: LockState = .locked,
        unlockCommitted: Bool = false,
        biometryAvailable: Bool = true,
        suspended: Bool = false,
        authenticationInProgress: Bool = false,
        failCount: Int = 0,
        lastFailure: Date? = nil
    ) -> Bool {
        PassiveAuthPolicy.shouldArm(
            state: state,
            unlockCommitted: unlockCommitted,
            biometryAvailable: biometryAvailable,
            suspended: suspended,
            authenticationInProgress: authenticationInProgress,
            failCount: failCount,
            lastFailure: lastFailure,
            now: now
        )
    }

    // MARK: - Arms only while the screen is actually covered

    func testLockedWithBiometry_arms() {
        XCTAssertTrue(shouldArm())
    }

    func testNotLocked_doesNotArm() {
        for state in [LockState.unlocked, .locking, .unlocking] {
            XCTAssertFalse(shouldArm(state: state), "must not arm in \(state)")
        }
    }

    // MARK: - Macs without Touch ID keep the button path

    func testNoBiometry_doesNotArm() {
        XCTAssertFalse(shouldArm(biometryAvailable: false))
    }

    // MARK: - Suspension (stand-down latch, cleared by the next lock)

    func testSuspended_doesNotArm() {
        XCTAssertFalse(shouldArm(suspended: true))
    }

    // MARK: - One LAContext at a time

    func testVisiblePromptInFlight_doesNotArm() {
        XCTAssertFalse(shouldArm(authenticationInProgress: true))
    }

    /// The state machine is still `.locked` while the success animation plays, so arming in
    /// that window would invalidate the evaluation that had just succeeded and swallow the
    /// unlock. The one-second lock tick lands inside that 400ms window often enough to
    /// matter, so this guard is what makes tick-driven re-arming safe.
    func testUnlockAlreadyCommitted_doesNotArm() {
        XCTAssertFalse(shouldArm(unlockCommitted: true))
    }

    // MARK: - Arming respects the button path's cooldown without feeding it

    func testFailuresBelowLimit_stillArm() {
        XCTAssertTrue(shouldArm(failCount: maxAttempts - 1, lastFailure: now))
    }

    func testAtLimitInsideCooldown_doesNotArm() {
        XCTAssertFalse(shouldArm(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-12)))
    }

    func testAtLimitAfterCooldown_armsAgain() {
        XCTAssertTrue(shouldArm(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-cooldown - 1)))
    }

    func testAtLimitExactlyAtCooldownBoundary_armsAgain() {
        XCTAssertTrue(shouldArm(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-cooldown)))
    }

    func testAtLimitWithNoRecordedFailure_arms() {
        XCTAssertTrue(shouldArm(failCount: maxAttempts, lastFailure: nil))
    }

    func testAnExpiredCooldownNeverOverridesTheOtherGuards() {
        XCTAssertFalse(
            shouldArm(state: .unlocking, unlockCommitted: true, biometryAvailable: false,
                      suspended: true, failCount: maxAttempts),
            "an armable rate-limit state must not resurrect arming on its own"
        )
    }

    // MARK: - Outcome mapping

    func testSuccess_unlocks() {
        XCTAssertEqual(PassiveAuthPolicy.outcome(.success), .unlock)
    }

    /// A palm or a bag strap on the sensor is indistinguishable from a wrong finger, so a
    /// rejection must not spend the button path's attempts or surface an error. Touch ID's
    /// own hardware lockout is the rate limiter, and it arrives as `.biometryLockout`.
    func testRejectedFinger_rearmsWithoutCountingAnAttempt() {
        XCTAssertEqual(PassiveAuthPolicy.outcome(.failure(.authenticationFailed)), .rearmImmediately)
    }

    func testStableConditions_standDownForTheSession() {
        let stable: [LAError.Code] = [
            .biometryLockout,        // hardware rate limit — the OS has taken over
            .biometryNotAvailable,
            .biometryNotEnrolled,
            .passcodeNotSet,
            .userCancel,
            .userFallback
        ]
        for code in stable {
            XCTAssertEqual(PassiveAuthPolicy.outcome(.failure(code)), .standDown, "\(code) cannot fix itself")
        }
    }

    func testRecoverableEndings_rearmFromTheTick() {
        let recoverable: [LAError.Code] = [
            .appCancel,        // the button path took the context
            .systemCancel,     // session switch, sleep, activation change
            .invalidContext
        ]
        for code in recoverable {
            XCTAssertEqual(
                PassiveAuthPolicy.outcome(.failure(code)),
                .rearmOnNextTick,
                "\(code) must recover, but only at tick pace"
            )
        }
    }

    /// Fail open: an unrecognised ending — a future error code, or an evaluation the system
    /// expired after hours armed — must recover rather than leave the sensor cold all
    /// session. Tick-gated re-arming is what makes defaulting to recovery safe.
    func testUnrecognisedEnding_rearmsFromTheTick() {
        // LAError.Code is an open ObjC error enum, so a code this build has never heard of
        // is representable — which is exactly the case that must not strand the sensor.
        let futureCode = LAError.Code(rawValue: -9999)!
        XCTAssertEqual(PassiveAuthPolicy.outcome(.failure(futureCode)), .rearmOnNextTick)

        let noCode = PassiveAuthResult(authenticated: false, errorCode: nil)
        XCTAssertEqual(PassiveAuthPolicy.outcome(noCode), .rearmOnNextTick)
    }

    /// The passive path has no way to express "count this against the user" — the absence
    /// of that case is what keeps an unattended sensor from locking out the password
    /// fallback. Guards against it being reintroduced.
    func testNoOutcomeCanSpendAnAttempt() {
        let everyEnding: [PassiveAuthResult] = [.success] + [
            .authenticationFailed, .userCancel, .userFallback, .systemCancel, .appCancel,
            .invalidContext, .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout,
            .passcodeNotSet
        ].map { PassiveAuthResult.failure($0) }

        for result in everyEnding {
            let outcome = PassiveAuthPolicy.outcome(result)
            XCTAssertTrue(
                [.unlock, .rearmImmediately, .rearmOnNextTick, .standDown].contains(outcome),
                "\(result) produced an outcome outside the non-counting set"
            )
        }
    }
}
