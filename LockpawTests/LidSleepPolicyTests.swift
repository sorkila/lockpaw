import XCTest
@testable import Lockpaw

final class LidSleepPolicyTests: XCTestCase {

    private let ac = LidSleepPolicy.Power(onBattery: false, batteryPercent: 80)

    private func decide(
        enabled: Bool = true, helperReady: Bool = true, locked: Bool = true,
        power: LidSleepPolicy.Power? = nil, thermal: LidSleepPolicy.Thermal = .nominal,
        cutOff: Bool = false
    ) -> LidSleepPolicy.Decision {
        LidSleepPolicy.decide(
            enabled: enabled, helperReady: helperReady, locked: locked,
            power: power ?? ac, thermal: thermal, cutOffForBattery: cutOff
        )
    }

    func testBlocksOnlyWhenEnabledReadyAndLocked() {
        XCTAssertTrue(decide().block)
        XCTAssertFalse(decide(enabled: false).block)
        XCTAssertFalse(decide(helperReady: false).block)
        XCTAssertFalse(decide(locked: false).block, "never a general keep-awake toggle")
    }

    func testHotMacSleeps() {
        XCTAssertTrue(decide(thermal: .fair).block)
        XCTAssertFalse(decide(thermal: .serious).block)
        XCTAssertFalse(decide(thermal: .critical).block)
    }

    func testBatteryFloorCutsOff() {
        let atFloor = decide(power: .init(onBattery: true, batteryPercent: 20))
        XCTAssertFalse(atFloor.block)
        XCTAssertTrue(atFloor.cutOffForBattery)
        XCTAssertTrue(decide(power: .init(onBattery: true, batteryPercent: 21)).block)
    }

    func testBatteryHysteresis() {
        // Cut off at 20%; a wobble to 22% must not flip it back on.
        XCTAssertFalse(decide(power: .init(onBattery: true, batteryPercent: 22), cutOff: true).block)
        let resumed = decide(power: .init(onBattery: true, batteryPercent: 25), cutOff: true)
        XCTAssertTrue(resumed.block)
        XCTAssertFalse(resumed.cutOffForBattery)
    }

    func testChargerClearsTheBatteryCutoff() {
        let plugged = decide(power: .init(onBattery: false, batteryPercent: 10), cutOff: true)
        XCTAssertTrue(plugged.block)
        XCTAssertFalse(plugged.cutOffForBattery)
    }

    func testUnreadableBatteryKeepsThePreviousCutoff() {
        XCTAssertFalse(decide(power: .init(onBattery: true, batteryPercent: nil), cutOff: true).block)
        XCTAssertTrue(decide(power: .init(onBattery: true, batteryPercent: nil), cutOff: false).block)
    }

    func testThermalStateMapping() {
        XCTAssertEqual(LidSleepPolicy.Thermal(.serious), .serious)
    }

    // MARK: - System lock

    func testAutoUnlockAfterMacUnlockNeedsAllThree() {
        XCTAssertTrue(SystemLockPolicy.unlocksAfterSystemUnlock(state: .locked, systemLockSeenDuringLock: true, settingEnabled: true))
        XCTAssertFalse(SystemLockPolicy.unlocksAfterSystemUnlock(state: .locked, systemLockSeenDuringLock: true, settingEnabled: false),
                       "off by default: Lockpaw stays locked")
        XCTAssertFalse(SystemLockPolicy.unlocksAfterSystemUnlock(state: .locked, systemLockSeenDuringLock: false, settingEnabled: true),
                       "a macOS unlock with no macOS lock during this session proves nothing")
        for state in [LockState.unlocked, .locking, .unlocking] {
            XCTAssertFalse(SystemLockPolicy.unlocksAfterSystemUnlock(state: state, systemLockSeenDuringLock: true, settingEnabled: true))
        }
    }

    func testMacLockIsNotAnAccessibilityRevocation() {
        XCTAssertTrue(SystemLockPolicy.forceUnlocksForAccessibility(trusted: false, systemScreenLocked: false))
        XCTAssertFalse(SystemLockPolicy.forceUnlocksForAccessibility(trusted: false, systemScreenLocked: true))
        XCTAssertFalse(SystemLockPolicy.forceUnlocksForAccessibility(trusted: true, systemScreenLocked: false))
    }

    // MARK: - Helper requirement

    func testRequirementIsAnchoredToTheTeam() {
        let req = SleepHelper.requirement(team: "78ACS592J2", identifiers: ["com.eriknielsen.lockpaw", "com.eriknielsen.lockpaw.debug"])
        XCTAssertTrue(req.contains("anchor apple generic"))
        XCTAssertTrue(req.contains("certificate leaf[subject.OU] = \"78ACS592J2\""))
        XCTAssertTrue(req.contains("identifier \"com.eriknielsen.lockpaw\" or identifier \"com.eriknielsen.lockpaw.debug\""))
    }

    /// An ad-hoc binary can claim any identifier, so without a team nothing may connect.
    func testUnsignedBuildsGetARequirementNothingSatisfies() {
        XCTAssertEqual(SleepHelper.requirement(team: nil, identifiers: ["x"]), "never")
        XCTAssertEqual(SleepHelper.requirement(team: "", identifiers: ["x"]), "never")
        XCTAssertEqual(SleepHelper.requirement(team: "AB\" or always", identifiers: ["x"]), "never")
    }

    /// The requirement string must compile, or every connection would be refused.
    func testRequirementCompiles() {
        var requirement: SecRequirement?
        let text = SleepHelper.requirement(team: "78ACS592J2", identifiers: SleepHelper.appIdentifiers)
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertEqual(SecRequirementCreateWithString("never" as CFString, [], &requirement), errSecSuccess)
    }
}
