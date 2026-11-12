import XCTest
@testable import Lockpaw

/// A downloaded update installs and relaunches at a quiet moment, never while guarded.
@MainActor
final class QuietInstallTests: XCTestCase {
    /// A Mac nobody has touched for an hour, Lockpaw unlocked long ago, installs on.
    private func quiet() -> QuietInstallPolicy.Snapshot {
        QuietInstallPolicy.Snapshot(
            installsAutomatically: true,
            lockState: .unlocked,
            passwordEntryOpen: false,
            authenticating: false,
            lidSleepHeld: false,
            macOSLocked: false,
            secondsIdle: 3600,
            secondsSinceLockpawUnlock: nil,
            secondsSinceSessionReturn: nil
        )
    }

    // MARK: - Policy

    func testInstallsWhenIdleLongEnough() {
        var s = quiet()
        s.secondsIdle = QuietInstallPolicy.idleThreshold
        XCTAssertEqual(QuietInstallPolicy.decide(s), .install(.idle))
    }

    func testWaitsWhileSomeoneIsWorking() {
        var s = quiet()
        s.secondsIdle = QuietInstallPolicy.idleThreshold - 1
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.inUse))
    }

    func testNeverWhileTheScreenIsGuarded() {
        for state in [LockState.locking, .locked, .unlocking] {
            var s = quiet()
            s.lockState = state
            XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.guarded), "\(state)")
            s.secondsSinceSessionReturn = 30
            XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.guarded), "\(state) after a wake")
        }
    }

    func testNeverDuringPasswordEntry() {
        var s = quiet()
        s.passwordEntryOpen = true
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.passwordEntry))
        s = quiet()
        s.authenticating = true
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.passwordEntry))
    }

    func testNeverWhileLidClosedModeHoldsSleep() {
        var s = quiet()
        s.lidSleepHeld = true
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.lidSleepHeld))
    }

    func testRespectsTheInstallSwitch() {
        var s = quiet()
        s.installsAutomatically = false
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.installsOff))
    }

    func testWaitsJustAfterLockpawUnlocks() {
        var s = quiet()
        s.secondsSinceLockpawUnlock = QuietInstallPolicy.settleAfterUnlock - 1
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.justUnlocked))
        s.secondsSinceLockpawUnlock = QuietInstallPolicy.settleAfterUnlock
        XCTAssertEqual(QuietInstallPolicy.decide(s), .install(.idle))
    }

    func testIdleUnderTheMacOSLockStillCounts() {
        var s = quiet()
        s.macOSLocked = true
        XCTAssertEqual(QuietInstallPolicy.decide(s), .install(.idle))
    }

    func testInstallsShortlyAfterTheSessionComesBack() {
        var s = quiet()
        s.secondsIdle = 2
        s.secondsSinceSessionReturn = QuietInstallPolicy.sessionReturnSettle - 1
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.inUse), "still settling")
        s.secondsSinceSessionReturn = QuietInstallPolicy.sessionReturnSettle
        XCTAssertEqual(QuietInstallPolicy.decide(s), .install(.sessionReturned))
        s.secondsSinceSessionReturn = QuietInstallPolicy.sessionReturnWindow + 1
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.inUse), "window over")
    }

    /// The unlock notification can be forged; only the window server's word counts.
    func testSessionReturnNeedsMacOSReallyUnlocked() {
        var s = quiet()
        s.secondsIdle = 2
        s.macOSLocked = true
        s.secondsSinceSessionReturn = 30
        XCTAssertEqual(QuietInstallPolicy.decide(s), .wait(.inUse))
    }

    // MARK: - Scheduler

    private final class FakeEnvironment: QuietInstallEnvironment {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var installsAutomatically = true
        var lockState: LockState = .unlocked
        var passwordEntryOpen = false
        var authenticating = false
        var lidSleepHeld = false
        var macOSLocked = false
        var idle: TimeInterval = 0
        var lockpawUnlockedAt: Date?
        /// Runs on every idle read: lets a test change the world between two reads.
        var onIdleRead: (() -> Void)?

        var secondsIdle: TimeInterval {
            onIdleRead?()
            return idle
        }
    }

    private var env: FakeEnvironment!
    private var scheduler: QuietInstallScheduler!
    private var installs = 0

    override func setUp() async throws {
        env = FakeEnvironment()
        scheduler = QuietInstallScheduler(environment: env)
        installs = 0
    }

    private func offer() {
        scheduler.offer(version: "1.8.0") { [weak self] in self?.installs += 1 }
    }

    func testNothingToInstallWithoutAnOffer() {
        env.idle = 3600
        XCTAssertFalse(scheduler.evaluate())
        XCTAssertEqual(installs, 0)
    }

    func testWaitsThenInstallsOnceIdle() {
        offer()
        XCTAssertFalse(scheduler.evaluate())
        env.idle = QuietInstallPolicy.idleThreshold
        XCTAssertTrue(scheduler.evaluate())
        XCTAssertEqual(installs, 1)
    }

    func testOneAttemptPerPendingUpdate() {
        offer()
        env.idle = 3600
        scheduler.evaluate()
        scheduler.evaluate()
        scheduler.noteSessionReturned()
        env.now += 30
        scheduler.evaluate()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(scheduler.isWaiting)
    }

    func testANewUpdateGetsItsOwnAttempt() {
        offer()
        env.idle = 3600
        scheduler.evaluate()
        offer()
        XCTAssertTrue(scheduler.isWaiting)
        scheduler.evaluate()
        XCTAssertEqual(installs, 2)
    }

    func testNotWhileLockedEvenIfIdle() {
        offer()
        env.idle = 3600
        env.lockState = .locked
        XCTAssertFalse(scheduler.evaluate())
        env.lockState = .unlocked
        env.lockpawUnlockedAt = env.now
        XCTAssertFalse(scheduler.evaluate(), "just unlocked")
        env.now += QuietInstallPolicy.settleAfterUnlock
        XCTAssertTrue(scheduler.evaluate())
        XCTAssertEqual(installs, 1)
    }

    /// The world is read again right before the call; a lock in between wins.
    func testRechecksImmediatelyBeforeInstalling() {
        offer()
        env.idle = 3600
        var reads = 0
        env.onIdleRead = { [unowned env] in
            reads += 1
            // After the deciding read, before the re-check.
            if reads == 1 { env!.lockState = .locking }
        }
        XCTAssertFalse(scheduler.evaluate())
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(scheduler.isWaiting, "no attempt spent")
    }

    func testSessionReturnInstallsAfterSettling() {
        offer()
        env.idle = 1
        scheduler.noteSessionReturned()
        XCTAssertFalse(scheduler.evaluate())
        env.now += QuietInstallPolicy.sessionReturnSettle
        XCTAssertTrue(scheduler.evaluate())
        XCTAssertEqual(installs, 1)
    }

    /// Wake, screensDidWake and unlock arrive together; the last one sets the clock.
    func testRepeatedSessionReturnsMoveTheMark() {
        offer()
        env.idle = 1
        scheduler.noteSessionReturned()
        env.now += QuietInstallPolicy.sessionReturnSettle - 2
        scheduler.noteSessionReturned()
        env.now += 2
        XCTAssertFalse(scheduler.evaluate())
        env.now += QuietInstallPolicy.sessionReturnSettle
        XCTAssertTrue(scheduler.evaluate())
    }

    func testASessionReturnBeforeTheOfferDoesNotCount() {
        env.idle = 1
        scheduler.noteSessionReturned()
        env.now += 30
        offer()
        XCTAssertFalse(scheduler.evaluate())
    }

    func testClearedOfferNeverInstalls() {
        offer()
        scheduler.clear("aborted")
        env.idle = 3600
        XCTAssertFalse(scheduler.evaluate())
        XCTAssertEqual(installs, 0)
        XCTAssertNil(scheduler.pendingVersion)
    }

    func testInstallSwitchTurnedOffWhilePending() {
        offer()
        env.installsAutomatically = false
        env.idle = 3600
        XCTAssertFalse(scheduler.evaluate())
        env.installsAutomatically = true
        XCTAssertTrue(scheduler.evaluate())
    }

    func testLockStatusRecordsTheUnlockMoment() {
        let then = Date(timeIntervalSinceReferenceDate: 42)
        LockStatus.shared.update(.locked, now: then)
        LockStatus.shared.update(.unlocked, now: then)
        XCTAssertEqual(LockStatus.shared.unlockedAt, then)
        LockStatus.shared.update(.unlocked, now: then + 100)
        XCTAssertEqual(LockStatus.shared.unlockedAt, then, "only a real unlock moves it")
    }
}
