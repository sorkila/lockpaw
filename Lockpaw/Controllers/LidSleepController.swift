import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "LidSleep")

/// Lid-closed mode, app side: registers the root helper through SMAppService, and while
/// Lockpaw is locked asks it to hold system sleep off — so closing the lid keeps the agents
/// running. Every decision goes through `LidSleepPolicy`; this class only gathers the inputs
/// (setting, helper status, lock state, battery, thermal state) and talks XPC.
///
/// The helper owns no policy of its own beyond its safety nets (clear at boot, clear on
/// SIGTERM, clear when no app is connected for a minute). Holding the XPC connection open
/// for the length of a lock is what keeps the dead-man switch quiet.
@MainActor
final class LidSleepController: ObservableObject {
    static let shared = LidSleepController()

    enum HelperStatus: Equatable {
        /// Not registered (the setting is off, or registration hasn't happened yet).
        case notRegistered
        /// Registered, waiting for the user to allow it in System Settings → Login Items.
        case requiresApproval
        case enabled
        /// This build can't run it — unsigned or ad-hoc (debug) builds, or the plist missing.
        case unavailable
    }

    @Published private(set) var helperStatus: HelperStatus = .notRegistered
    /// Whether the helper reports sleep held off right now. For the Settings status line.
    @Published private(set) var sleepHeld = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.daemon(plistName: SleepHelper.plistName)
    private var connection: NSXPCConnection?
    private var locked = false
    private var cutOffForBattery = false
    private var requested: Bool?
    private var powerTimer: Timer?
    private var observers: [Any] = []

    private var settingEnabled: Bool { UserDefaults.standard.bool(forKey: Constants.lidClosedModeKey) }

    private init() {
        refreshStatus()
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reevaluate() } })
        // pmset's disablesleep can reset across a sleep/wake cycle, so re-assert after wake.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reapply() } })
    }

    // MARK: - Lock lifecycle

    /// Called on launch: a block left by a crashed previous run is cleared (the helper's
    /// dead-man switch would get there too, a minute later).
    func applicationDidLaunch() {
        guard settingEnabled, helperStatus == .enabled else { return }
        send(false)
    }

    func lockBegan() {
        locked = true
        cutOffForBattery = false
        reevaluate()
        startPowerChecks()
    }

    func lockEnded() {
        locked = false
        stopPowerChecks()
        reevaluate()
    }

    // MARK: - Settings

    func refreshStatus() {
        guard !Self.unsignedBuild else { helperStatus = .unavailable; return }
        switch service.status {
        case .enabled: helperStatus = .enabled
        case .requiresApproval: helperStatus = .requiresApproval
        case .notRegistered: helperStatus = .notRegistered
        case .notFound: helperStatus = .unavailable
        @unknown default: helperStatus = .notRegistered
        }
    }

    /// The helper only accepts a team-signed app (see `SleepHelper.requirement`), so an
    /// ad-hoc debug build can't use lid-closed mode at all.
    private static let unsignedBuild = SleepHelper.ownTeamIdentifier() == nil

    /// Turning the setting on registers the helper (the user then approves it in Login Items);
    /// turning it off lets the Mac sleep and unregisters it — launchd's SIGTERM clears
    /// disablesleep on the way out as a second line.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constants.lidClosedModeKey)
        lastError = nil
        if enabled {
            do {
                try service.register()
            } catch {
                logger.error("register failed: \(error.localizedDescription, privacy: .public)")
            }
            refreshStatus()
            if helperStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            if helperStatus == .unavailable { lastError = "This build isn't signed, so the helper can't run." }
        } else {
            send(false)
            service.unregister { [weak self] error in
                if let error { logger.error("unregister failed: \(error.localizedDescription, privacy: .public)") }
                Task { @MainActor in self?.refreshStatus() }
            }
        }
        reevaluate()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - Policy

    private func reevaluate() {
        refreshStatus()
        let decision = LidSleepPolicy.decide(
            enabled: settingEnabled,
            helperReady: helperStatus == .enabled,
            locked: locked,
            power: Self.currentPower(),
            thermal: LidSleepPolicy.Thermal(ProcessInfo.processInfo.thermalState),
            cutOffForBattery: cutOffForBattery
        )
        cutOffForBattery = decision.cutOffForBattery
        if decision.block != requested { send(decision.block) }
    }

    private func reapply() {
        guard let requested, requested else { return }
        send(true)
    }

    private func startPowerChecks() {
        stopPowerChecks()
        powerTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.lidPowerCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    private func stopPowerChecks() {
        powerTimer?.invalidate()
        powerTimer = nil
    }

    // MARK: - XPC

    private func send(_ blocked: Bool) {
        // Never open a connection just to say "no" to a helper that isn't there.
        guard blocked || helperStatus == .enabled else { requested = blocked; return }
        requested = blocked
        // `requested` is what we last asked for. Any failure forgets it, so the next
        // re-evaluation (the 30s power check while locked) asks again instead of assuming
        // the helper already holds the state — a lid closed after a failed first request
        // would otherwise sleep the Mac with the setting on and "Ready".
        let proxy = helperProxy { [weak self] error in
            Task { @MainActor in
                logger.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
                self?.lastError = "Couldn't reach the helper."
                self?.sleepHeld = false
                if self?.requested == blocked { self?.requested = nil }
            }
        }
        proxy?.setSleepBlocked(blocked) { [weak self] held, message in
            Task { @MainActor in
                self?.sleepHeld = held
                self?.lastError = message
                if let message { logger.error("helper refused: \(message, privacy: .public)") }
                if held != blocked, self?.requested == blocked { self?.requested = nil }
            }
        }
    }

    private func helperProxy(onError: @escaping (Error) -> Void) -> SleepHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: SleepHelper.label, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: SleepHelperProtocol.self)
            // Only talk to our own helper, signed by the same team.
            connection.setCodeSigningRequirement(SleepHelper.requirement(
                team: SleepHelper.ownTeamIdentifier(), identifiers: [SleepHelper.helperIdentifier]
            ))
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                    self?.requested = nil
                }
            }
            // The helper restarted (crash, or an update adopted while idle) and cleared its
            // block on the way up; put back whatever we last asked for.
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.reapply() }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? SleepHelperProtocol
    }

    // MARK: - Power

    private static func currentPower() -> LidSleepPolicy.Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return LidSleepPolicy.Power(onBattery: false, batteryPercent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return LidSleepPolicy.Power(onBattery: onBattery, batteryPercent: current * 100 / max)
        }
        return LidSleepPolicy.Power(onBattery: onBattery, batteryPercent: nil)
    }
}
