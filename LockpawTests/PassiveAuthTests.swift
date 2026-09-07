import XCTest
import LocalAuthentication
@testable import Lockpaw

final class PassiveAuthTests: XCTestCase {

    private let cooldown = Constants.Timing.authRateLimitCooldown
    private let maxAttempts = Constants.Timing.maxAuthAttempts
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func decide(
        state: LockState = .locked,
        biometryAvailable: Bool = true,
        authenticationInProgress: Bool = false,
        failCount: Int = 0,
        lastFailure: Date? = nil
    ) -> PassiveArmDecision {
        PassiveAuthPolicy.decide(
            state: state,
            biometryAvailable: biometryAvailable,
            authenticationInProgress: authenticationInProgress,
            failCount: failCount,
            lastFailure: lastFailure,
            now: now
        )
    }

    // MARK: - Arms only while the screen is actually covered

    func testLockedWithBiometry_arms() {
        XCTAssertEqual(decide(), .arm)
    }

    func testNotLocked_doesNotArm() {
        for state in [LockState.unlocked, .locking, .unlocking] {
            XCTAssertEqual(decide(state: state), .doNotArm, "must not arm in \(state)")
        }
    }

    // MARK: - Macs without Touch ID keep the button path

    func testNoBiometry_doesNotArm() {
        XCTAssertEqual(decide(biometryAvailable: false), .doNotArm)
    }

    // MARK: - One LAContext at a time

    func testVisiblePromptInFlight_doesNotArm() {
        XCTAssertEqual(decide(authenticationInProgress: true), .doNotArm)
    }

    // MARK: - Rate limit

    func testFailuresBelowLimit_stillArm() {
        XCTAssertEqual(decide(failCount: maxAttempts - 1, lastFailure: now), .arm)
    }

    func testAtLimitInsideCooldown_armsAfterRemainingTime() {
        let elapsed: TimeInterval = 12
        let decision = decide(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-elapsed))
        XCTAssertEqual(decision, .armAfter(cooldown - elapsed))
    }

    func testAtLimitAfterCooldown_armsAgain() {
        XCTAssertEqual(
            decide(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-cooldown - 1)),
            .arm
        )
    }

    func testAtLimitExactlyAtCooldownBoundary_armsAgain() {
        XCTAssertEqual(decide(failCount: maxAttempts, lastFailure: now.addingTimeInterval(-cooldown)), .arm)
    }

    func testAtLimitWithNoRecordedFailure_arms() {
        XCTAssertEqual(decide(failCount: maxAttempts, lastFailure: nil), .arm)
    }

    func testRateLimitNeverOverridesTheOtherGuards() {
        // A pending cooldown must not resurrect arming on a Mac that cannot arm at all.
        let decision = decide(
            state: .unlocking,
            biometryAvailable: false,
            failCount: maxAttempts,
            lastFailure: now
        )
        XCTAssertEqual(decision, .doNotArm)
    }

    // MARK: - Outcome mapping

    func testSuccess_unlocks() {
        XCTAssertEqual(PassiveAuthPolicy.outcome(.success), .unlock)
    }

    func testRejectedFinger_countsAndRearms() {
        XCTAssertEqual(PassiveAuthPolicy.outcome(.failure(.authenticationFailed)), .countFailureAndRearm)
    }

    func testEveryOtherEnding_standsDownWithoutSpendingAnAttempt() {
        let notTheUsersFault: [LAError.Code] = [
            .appCancel,          // the button path took the context
            .systemCancel,       // session switch, sleep
            .userCancel,
            .userFallback,
            .invalidContext,
            .biometryLockout,
            .biometryNotAvailable,
            .biometryNotEnrolled,
            .passcodeNotSet
        ]
        for code in notTheUsersFault {
            XCTAssertEqual(
                PassiveAuthPolicy.outcome(.failure(code)),
                .standDown,
                "\(code) must not burn an unlock attempt"
            )
        }
    }

    func testFailureWithNoErrorCode_standsDown() {
        let result = PassiveAuthResult(authenticated: false, errorCode: nil)
        XCTAssertEqual(PassiveAuthPolicy.outcome(result), .standDown)
    }
}
