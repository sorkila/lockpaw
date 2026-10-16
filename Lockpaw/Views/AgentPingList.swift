import SwiftUI

/// The agents waiting on the user — the standing companion to the glow pulses, shown
/// until unlock. A tally first, readable at a glance ("1 waiting · 2 done", once more than
/// one session has pinged), then one row per session: agent, state, wait time. Rows are
/// urgent first and capped so a busy afternoon cannot push the unlock prompt off a small
/// screen; the tally still counts everyone.
///
/// No project names unless the user opts in (`Constants.lockScreenShowsProjectsKey`):
/// anyone walking past can read a lock screen. Notifications keep the project.
struct AgentPingList: View {
    let queue: AgentPingQueue
    let breathe: CGFloat

    @AppStorage(Constants.lockScreenShowsProjectsKey) private var showsProjects = false

    static let maxRows = 3

    var body: some View {
        VStack(spacing: 10) {
            if queue.pings.count > 1 {
                tally
            }
            VStack(spacing: 6) {
                ForEach(queue.rows.prefix(Self.maxRows)) { ping in
                    row(ping)
                }
                if queue.pings.count > Self.maxRows {
                    Text("and \(queue.pings.count - Self.maxRows) more")
                        .font(.lockCaption)
                        .foregroundStyle(.white.opacity(0.25))
                        .tracking(0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Label-sized and brighter than the rows; only an error carries a marker, the small
    /// red dot that separates it from a session waiting on the user.
    private var tally: some View {
        HStack(spacing: 6) {
            ForEach(Array(queue.tally.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Text("\u{00B7}")
                        .foregroundStyle(.white.opacity(0.25))
                }
                if entry.status == .error {
                    marker(.error)
                }
                Text(entry.label)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.lockLabel)
        .tracking(0.3)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func row(_ ping: AgentPing) -> some View {
        HStack(spacing: 6) {
            marker(ping.kind.status)
            Text(ping.summary(includingProject: showsProjects))
                .font(.lockCaption)
                .foregroundStyle(.white.opacity(0.4))
            Text("\u{00B7}")
                .font(.lockCaption)
                .foregroundStyle(.white.opacity(0.25))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Constants.formatWaitTime(context.date.timeIntervalSince(ping.receivedAt)))
                    .font(.lockMono)
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .tracking(0.5)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func marker(_ status: AgentPingStatus) -> some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: 5, height: 5)
            .opacity(0.55 + breathe * 0.3)
    }
}

extension AgentPingStatus {
    /// The row's marker: teal done, amber waiting, red for an error — the one place red
    /// appears for an agent, since the glow itself stays amber.
    var dotColor: Color {
        switch self {
        case .done, .attention: return Color("LockpawTeal")
        case .waiting: return Color("LockpawAmber")
        case .error: return Color("LockpawError")
        }
    }
}
