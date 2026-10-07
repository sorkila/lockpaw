import Foundation
import os.log

private let logger = Logger(subsystem: SleepHelper.label, category: "SleepBlocker")

/// Machine-global lid-closed sleep control via `pmset -a disablesleep`.
///
/// Why shell out: no in-process call keeps a lid-closed Mac with no external display awake.
/// Public IOPMAssertions (and so `caffeinate`) are documented not to survive a lid close,
/// and the private `SleepDisabled` routes either return success without effect or are refused
/// even as root (measured by Adrafinil on macOS 26.3, MIT, github.com/kageroumado/adrafinil).
/// `/usr/bin/pmset` is Apple's tested implementation and runs only on rare state flips.
///
/// `disablesleep` is a persistent power preference: it survives this process, crashes and
/// reboots. So it is cleared when the helper starts (boot, via RunAtLoad), on SIGTERM
/// (shutdown, unregister), and by the dead-man switch when the app goes away mid-block.
final class SleepBlocker {
    private let queue = DispatchQueue(label: "\(SleepHelper.label).blocker")
    private var blocked = false

    var isBlocked: Bool { queue.sync { blocked } }

    init() {
        // Crash recovery: a block left behind by a previous instance must not outlive it.
        do { try runPMSet(disabled: false) } catch {
            logger.error("startup clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Serialized: XPC calls arrive on their own queues.
    func set(blocked newValue: Bool) throws {
        try queue.sync {
            try runPMSet(disabled: newValue)
            blocked = newValue
            logger.notice("sleep blocked = \(newValue, privacy: .public)")
        }
    }

    private func runPMSet(disabled: Bool) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        task.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        task.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        try task.run()
        // Bounded: this runs under the blocker's queue, and a wedged pmset must not wedge
        // every later call — above all the one that turns sleep back on.
        guard exited.wait(timeout: .now() + 10) == .success else {
            task.terminate()
            throw HelperError("pmset timed out")
        }
        guard task.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw HelperError(message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                              ?? "pmset exited \(task.terminationStatus)")
        }
    }
}

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
