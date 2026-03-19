import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.bevaka", category: "SleepPreventer")

class SleepPreventer {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isActive = false

    func preventSleep() {
        guard !isActive else { return }
        let reason = "Bevaka: Screen locked — preventing idle sleep" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason, &assertionID
        )
        if result == kIOReturnSuccess { isActive = true }
        else { logger.error("Failed to create sleep assertion: \(result)") }
    }

    func allowSleep() {
        guard isActive else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess { logger.error("Failed to release sleep assertion: \(result)") }
        isActive = false
    }

    deinit { allowSleep() }
}
