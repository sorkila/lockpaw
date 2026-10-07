import Foundation
import os.log

/// LockpawHelper — the root LaunchDaemon behind lid-closed mode. It does one thing: turn
/// system sleep off while Lockpaw is locked, and back on. Registered by the app through
/// SMAppService (the user approves it in System Settings → Login Items) and only ever
/// talks to a Lockpaw build signed by the same team.

private let logger = Logger(subsystem: SleepHelper.label, category: "Helper")

/// Records the on-disk binary at launch, so a Sparkle update that swapped it can be adopted:
/// the helper exits while idle and launchd (KeepAlive) relaunches the new image.
struct ExecutableIdentity: Equatable {
    let inode: UInt64
    let modified: Date?

    static func current() -> ExecutableIdentity? {
        guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ExecutableIdentity(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
    }
}

final class HelperService: NSObject, SleepHelperProtocol {
    private let blocker: SleepBlocker
    private let launchedAs: ExecutableIdentity?

    init(blocker: SleepBlocker, launchedAs: ExecutableIdentity?) {
        self.blocker = blocker
        self.launchedAs = launchedAs
    }

    func setSleepBlocked(_ blocked: Bool, reply: @escaping (Bool, String?) -> Void) {
        do {
            try blocker.set(blocked: blocked)
            reply(blocker.isBlocked, nil)
        } catch {
            logger.error("setSleepBlocked(\(blocked, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            reply(blocker.isBlocked, error.localizedDescription)
        }
        if !blocked { exitIfReplaced() }
    }

    func status(reply: @escaping (Bool, String) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        reply(blocker.isBlocked, version)
        exitIfReplaced()
    }

    /// Only while idle: exiting is safe then (nothing to clear), and the relaunch picks up
    /// the binary an update put on disk.
    private func exitIfReplaced() {
        guard !blocker.isBlocked, let launchedAs, let now = ExecutableIdentity.current(), now != launchedAs else { return }
        logger.notice("binary replaced by an update — exiting so launchd relaunches it")
        exit(0)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let blocker = SleepBlocker()
    private let launchedAs = ExecutableIdentity.current()
    private let requirement = SleepHelper.requirement(
        team: SleepHelper.ownTeamIdentifier(), identifiers: SleepHelper.appIdentifiers
    )
    private let lock = NSLock()
    private var connections = 0
    private var generation = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The kernel enforces this on every message, not just at accept time.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: SleepHelperProtocol.self)
        connection.exportedObject = HelperService(blocker: blocker, launchedAs: launchedAs)
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        lock.withLock { connections += 1; generation += 1 }
        connection.resume()
        return true
    }

    /// Dead-man switch: the app owns the block. If its last connection drops while sleep is
    /// blocked (crash, force quit, logout) and nothing reconnects within the grace period,
    /// let the Mac sleep again — nothing else ever would.
    private func connectionEnded() {
        let (remaining, ended) = lock.withLock { () -> (Int, Int) in
            connections -= 1
            generation += 1
            return (connections, generation)
        }
        guard remaining <= 0, blocker.isBlocked else { return }
        logger.notice("app disconnected while blocked — clearing in \(SleepHelper.deadManGrace, privacy: .public)s unless it returns")
        DispatchQueue.global().asyncAfter(deadline: .now() + SleepHelper.deadManGrace) { [weak self] in
            guard let self else { return }
            let unchanged = self.lock.withLock { self.generation == ended && self.connections <= 0 }
            guard unchanged, self.blocker.isBlocked else { return }
            logger.warning("no app connection for \(SleepHelper.deadManGrace, privacy: .public)s — allowing sleep")
            try? self.blocker.set(blocked: false)
        }
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: SleepHelper.label)
listener.delegate = delegate
listener.resume()

// launchd sends SIGTERM at shutdown and on unregister. disablesleep would otherwise survive
// into the next boot's login window.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    try? delegate.blocker.set(blocked: false)
    exit(0)
}
termination.resume()

logger.notice("helper started (uid \(getuid(), privacy: .public))")
RunLoop.main.run()
