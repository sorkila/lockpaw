import Foundation

/// App side of the session board. Re-reads the store when `lockpaw session` nudges and
/// publishes the sessions for the lock screen and the menu bar. It raises no alerts of its
/// own — the `lockpaw ping` hooks already glow and notify. Event-driven only: no timers,
/// no polling, no file watching.
@MainActor
final class AgentSessionMonitor: ObservableObject {
    static let shared = AgentSessionMonitor()

    /// Live sessions in slot order.
    @Published private(set) var sessions: [AgentSession] = []

    private let store: AgentSessionStore
    private var observer: NSObjectProtocol?
    private var reloadWork: DispatchWorkItem?

    init(store: AgentSessionStore = .standard) {
        self.store = store
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Constants.sessionsDistributedName), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        // Sessions from before the last reboot can't still be running. Only needed once:
        // anything written after launch is necessarily after the boot.
        if let boot = AgentSessionStore.systemBootTime {
            store.pruneSessions(lastEventBefore: boot)
        }
        reload()
    }

    /// Parallel subagents arrive as a burst of nudges — coalesce them into one read.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.sessionReloadCoalesce, execute: work)
    }

    private func reload() {
        let loaded = store.loadAll()
        if loaded != sessions { sessions = loaded }
    }
}
