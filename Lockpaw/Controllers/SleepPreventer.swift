import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "SleepPreventer")

class SleepPreventer {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var activityAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var activityTimer: Timer?
    internal private(set) var isActive = false

    func preventSleep() {
        guard !isActive else { return }
        let reason = "Lockpaw: Screen covered - preventing display sleep & screensaver" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &assertionID
        )
        guard result == kIOReturnSuccess else {
            logger.error("Failed to create display-sleep assertion: \(result)")
            return
        }
        isActive = true
        startActivityTimer()
    }

    func allowSleep() {
        guard isActive else { return }
        stopActivityTimer()
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess { logger.error("Failed to release assertion: \(result)") }
        isActive = false
    }

    private func startActivityTimer() {
        stopActivityTimer()
        declareUserActivity()
        activityTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.Timing.userActivityRefreshInterval,
            repeats: true
        ) { [weak self] _ in self?.declareUserActivity() }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func declareUserActivity() {
        let result = IOPMAssertionDeclareUserActivity(
            "Lockpaw active" as CFString,
            kIOPMUserActiveLocal,
            &activityAssertionID
        )
        if result != kIOReturnSuccess { logger.error("DeclareUserActivity failed: \(result)") }
    }

    deinit { allowSleep() }
}
