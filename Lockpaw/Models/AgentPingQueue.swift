import Foundation

/// What a ping means on the lock screen, grouped the way the tally counts it.
enum AgentPingStatus: CaseIterable, Equatable {
    case waiting
    case error
    case done
    /// A bare ping with no payload: something wants the user, nothing says what.
    case attention

    /// Blocked on the user, or stopped and needing a look. These outrank a finished turn
    /// for the glow: an amber "needs permission" must not be repainted teal because a
    /// different session finished afterwards.
    var isUrgent: Bool { self == .waiting || self == .error }

    /// The glow's colour. Errors glow amber, not red: red is for auth failure and danger,
    /// and a red full-screen bloom on a lock screen reads as an intrusion. The red marker
    /// on the row and in the tally carries the difference.
    var glowTone: AgentGlowTone { isUrgent ? .amber : .teal }

    /// The tally's word for `count` sessions in this state.
    func tallyLabel(count: Int) -> String {
        switch self {
        case .waiting: return "\(count) waiting"
        case .error: return count == 1 ? "1 error" : "\(count) errors"
        case .done: return "\(count) done"
        case .attention: return count == 1 ? "1 needs you" : "\(count) need you"
        }
    }
}

/// The two colours the agent glow can take.
enum AgentGlowTone: Equatable {
    case teal
    case amber
}

extension AgentPing.Kind {
    var status: AgentPingStatus {
        switch self {
        case .finished: return .done
        case .permission, .needsInput: return .waiting
        case .rateLimited, .failed: return .error
        case .attention: return .attention
        }
    }
}

/// The agents waiting on the user while the screen is locked, one entry per session, in
/// arrival order. Pure, so the precedence rules are unit-tested.
struct AgentPingQueue: Equatable {
    private(set) var pings: [AgentPing] = []

    var isEmpty: Bool { pings.isEmpty }
    var latest: AgentPing? { pings.last }

    /// A session's newest ping replaces its entry. A repeat in the same state keeps the
    /// original entry, so the wait time counts from when the agent started waiting —
    /// Claude's `idle_prompt` restates a `Stop` a minute later and must not reset it to "now".
    mutating func record(_ ping: AgentPing) {
        if let index = pings.firstIndex(where: { $0.id == ping.id }) {
            if pings[index].kind == ping.kind { return }
            pings.remove(at: index)
        }
        pings.append(ping)
    }

    mutating func clear() {
        pings.removeAll()
    }

    /// The ping the glow speaks for: the most urgent outstanding one, the latest breaking
    /// ties. Nil when nothing has pinged.
    var glowPing: AgentPing? {
        pings.last(where: { $0.kind.status.isUrgent }) ?? pings.last
    }

    /// Teal until something pings; then the colour of `glowPing`.
    var glowTone: AgentGlowTone { glowPing?.kind.status.glowTone ?? .teal }

    /// Rows for the lock screen: urgent first, newest first within each, so the row that
    /// explains an amber glow is never the one pushed into "and N more".
    var rows: [AgentPing] {
        let newestFirst = pings.reversed()
        return newestFirst.filter { $0.kind.status.isUrgent } + newestFirst.filter { !$0.kind.status.isUrgent }
    }

    /// Sessions per state, in `AgentPingStatus` order (urgent first, like the rows), zero
    /// counts left out: "1 waiting · 2 done".
    var tally: [AgentPingTally] {
        AgentPingStatus.allCases.compactMap { status in
            let count = pings.filter { $0.kind.status == status }.count
            return count > 0 ? AgentPingTally(status: status, count: count) : nil
        }
    }
}

/// One segment of the lock screen's tally.
struct AgentPingTally: Equatable, Identifiable {
    let status: AgentPingStatus
    let count: Int

    var id: AgentPingStatus { status }
    var label: String { status.tallyLabel(count: count) }
}
