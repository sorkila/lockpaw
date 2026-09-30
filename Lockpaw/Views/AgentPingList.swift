import SwiftUI

/// The agents waiting on the user, newest first — the standing companion to the glow
/// pulses, shown until unlock. Capped so a busy afternoon cannot push the unlock
/// prompt off a small screen.
struct AgentPingList: View {
    let pings: [AgentPing]
    let breathe: CGFloat

    static let maxRows = 4

    var body: some View {
        VStack(spacing: 6) {
            ForEach(pings.suffix(Self.maxRows).reversed()) { ping in
                row(ping)
            }
            if pings.count > Self.maxRows {
                Text("and \(pings.count - Self.maxRows) more")
                    .font(.lockCaption)
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func row(_ ping: AgentPing) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ping.kind.color)
                .frame(width: 5, height: 5)
                .opacity(0.55 + breathe * 0.3)
            Text(ping.summary)
                .font(.lockCaption)
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.5)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Constants.formatWaitTime(context.date.timeIntervalSince(ping.receivedAt)))
                    .font(.lockMono)
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(0.5)
            }
        }
        .lineLimit(1)
    }
}

extension AgentPing.Kind {
    /// Teal when the agent is done, amber when it is blocked on the user, red when its
    /// turn died on an API error. A bare ping keeps the original teal.
    var color: Color {
        switch self {
        case .finished, .attention: return Color("LockpawTeal")
        case .permission, .needsInput: return Color("LockpawAmber")
        case .rateLimited, .failed: return Color("LockpawError")
        }
    }
}

extension AgentPingQueue {
    /// The glow takes the colour of whoever pinged last.
    var glowColor: Color { latest?.kind.color ?? Color("LockpawTeal") }
}
