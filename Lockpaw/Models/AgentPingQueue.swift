import Foundation

/// The agents waiting on the user while the screen is locked, oldest first. A repeat
/// ping from the same session replaces its row rather than adding another.
struct AgentPingQueue: Equatable {
    private(set) var pings: [AgentPing] = []

    var isEmpty: Bool { pings.isEmpty }
    var latest: AgentPing? { pings.last }

    mutating func record(_ ping: AgentPing) {
        pings.removeAll { $0.id == ping.id }
        pings.append(ping)
    }

    mutating func clear() {
        pings.removeAll()
    }
}
