import SwiftUI
import AppKit

// Agent Sessions — status vocabulary and the lock-screen status dock. Depends only on
// SwiftUI, AppKit, the shared session model and Constants, so the dock renders standalone
// (previews, snapshot renders) without a LockController or the session monitor.
// The lock screen names a session by its Claude title or its folder name — never its path,
// the same rule pings follow (anyone walking past can read it).

// MARK: - Status vocabulary

extension AgentSessionStatus {
    /// The bare glyph that sits inside `SessionStatusBadge`'s tinted circle.
    var badgeSymbolName: String {
        switch self {
        case .idle: return "minus"
        case .working: return "ellipsis"
        case .needsYou: return "hand.raised.fill"
        case .done: return "checkmark"
        case .error: return "exclamationmark"
        }
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .needsYou: return "needs you"
        case .done: return "done"
        case .error: return "error"
        }
    }

    /// Color as signal — teal (safe) → amber (caution) → red (danger); the quiet states
    /// recede into white at low opacity.
    var tint: Color {
        switch self {
        case .idle: return .white.opacity(0.5)
        case .working: return .white.opacity(0.75)
        case .needsYou: return .lockpawAsset("LockpawAmber", red: 1.0, green: 0.624, blue: 0.263)
        case .done: return .lockpawAsset("LockpawTeal", red: 0.0, green: 0.831, blue: 0.667)
        case .error: return .lockpawAsset("LockpawError", red: 1.0, green: 0.231, blue: 0.188)
        }
    }

    /// The states that are waiting on you. Their dock tile lights up and their badge glows;
    /// the rest stay quiet.
    fileprivate var asksForYou: Bool { self == .needsYou || self == .error }
}

extension AgentSession {
    /// The name a session goes by on the dock: the title Claude gave it (what its terminal
    /// tab shows), else its folder name. The slot number is added only when another live
    /// session would show the same name.
    func dockName(among sessions: [AgentSession]) -> String {
        let label = displayTitle ?? folderName
        let base = label.isEmpty ? "Claude" : AgentSession.middleTruncated(label, to: 22)
        let shared = sessions.contains { $0.id != id && ($0.displayTitle ?? $0.folderName) == label }
        return shared ? "\(base) #\(slot)" : base
    }

    /// The second line of a dock tile.
    func detail(now: Date) -> String {
        let age = max(0, now.timeIntervalSince(statusSince))
        switch status {
        case .working:
            let count = runningAgents.count
            if count == 0 { return AgentSession.shortAge(age) }
            return count == 1 ? "1 agent" : "\(count) agents"
        case .needsYou:
            return AgentSession.shortAge(age)
        case .done, .error:
            return age < 60 ? "just now" : "\(AgentSession.shortAge(age)) ago"
        case .idle:
            return "waiting"
        }
    }

    /// One plain menu bar item: "bugApp — working · 2 running", with the title after the
    /// folder name when Claude has given the session one.
    func menuLine(now: Date) -> String {
        let name = displayTitle.map { "\(folderName): \(AgentSession.middleTruncated($0, to: 40))" } ?? folderName
        let detail = status == .working && !runningAgents.isEmpty
            ? "\(runningAgents.count) running"
            : detail(now: now)
        return "\(name) \u{2014} \(status.label) \u{00B7} \(detail)"
    }

    /// One VoiceOver label per tile / row. `name` is the dock name.
    func accessibilityLabel(now: Date, name: String? = nil) -> String {
        ["Session \(slot)", name, status.label, detail(now: now)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// "just now" under a minute, otherwise "7m ago" / "1h 20m ago".
    static func ago(_ date: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(date))
        return age < 60 ? "just now" : "\(shortAge(age)) ago"
    }

    /// Shortens a long name around the middle ("very-long…name"), keeping both ends.
    static func middleTruncated(_ text: String, to limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let tail = (limit - 1) / 2
        return String(text.prefix(limit - 1 - tail)) + "\u{2026}" + String(text.suffix(tail))
    }

    /// Compact age: "<1m", "7m", or "1h 20m".
    static func shortAge(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1m" }
        let minutes = Int(s) / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

extension Color {
    /// An asset-catalog color, or its DESIGN.md value when the catalog isn't loaded
    /// (standalone renders) — so a snapshot shows the same signal colors as the app.
    fileprivate static func lockpawAsset(_ name: String, red: Double, green: Double, blue: Double) -> Color {
        if let color = NSColor(named: name) { return Color(nsColor: color) }
        return Color(.sRGB, red: red, green: green, blue: blue)
    }
}

// MARK: - Badge

/// A 28pt tinted disc with the status glyph centered in it. Loud states (needs you, error)
/// carry a soft static glow. Nothing in it moves.
struct SessionStatusBadge: View {
    let status: AgentSessionStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(status.tint.opacity(0.16))
            Circle()
                .strokeBorder(status.tint.opacity(0.22), lineWidth: 0.5)
            Image(systemName: status.badgeSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.tint)
        }
        .frame(width: 28, height: 28)
        .shadow(color: status.asksForYou ? status.tint.opacity(0.35) : .clear,
                radius: status.asksForYou ? 6 : 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Dock

/// What the dock's detail card is showing: one session, or the sessions behind "+N".
enum SessionDockSelection: Hashable {
    case session(String)
    case more
}

/// The lock screen's session dock, live: ages refresh every 30s, nothing else ticks.
struct LockScreenSessionDock: View {
    let sessions: [AgentSession]
    var compact: Bool = false

    var body: some View {
        if sessions.isEmpty {
            EmptyView()
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SessionStatusDock(sessions: sessions, now: context.date, compact: compact)
            }
        }
    }
}

/// One glass bar holding a tile per session, in stable slot order. Tiles size to their text
/// (with a floor, so most status changes don't resize the bar). Max five tiles, then four
/// plus a "+N" tile. Too narrow for full tiles, it drops the age/agent detail rather than
/// truncating.
///
/// Clicking a tile (or "+N") opens a detail card above it. The card closes on a second
/// click, a click on the card, or shortly after the pointer leaves the dock. All motion is
/// one-shot and event-driven — nothing loops.
struct SessionStatusDock: View {
    let sessions: [AgentSession]
    let now: Date
    var compact: Bool

    @State private var selection: SessionDockSelection?
    @State private var cardShown: Bool
    @State private var overDock = false
    @State private var overCard = false
    /// Bumped by every open/close so a stale delayed close or unmount never lands.
    @State private var generation = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `selection` opens that card on first render — for previews and snapshot renders.
    init(sessions: [AgentSession], now: Date, compact: Bool = false,
         selection: SessionDockSelection? = nil) {
        self.sessions = sessions
        self.now = now
        self.compact = compact
        _selection = State(initialValue: selection)
        _cardShown = State(initialValue: selection != nil)
    }

    /// First four plus a "+N" tile once there are more than five; otherwise up to five.
    private var visible: [AgentSession] {
        sessions.count > 5 ? Array(sessions.prefix(4)) : Array(sessions.prefix(5))
    }

    /// The sessions folded into the "+N" tile.
    private var hidden: [AgentSession] {
        sessions.count > 5 ? Array(sessions.dropFirst(4)) : []
    }

    private var motion: Animation? { reduceMotion ? nil : Constants.Anim.standard }

    var body: some View {
        if sessions.isEmpty {
            EmptyView()
        } else {
            ViewThatFits(in: .horizontal) {
                bar(showsDetail: true)
                bar(showsDetail: false)
            }
            .onHover { overDock = $0; pointerMoved() }
            .onChange(of: sessions.map(\.id)) { _, ids in
                switch selection {
                case .session(let id)? where !ids.contains(id): close()
                case .more? where hidden.isEmpty: close()
                default: break
                }
            }
            .animation(motion, value: visible.map(\.status))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Claude sessions")
        }
    }

    // MARK: Bar

    private func bar(showsDetail: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    // No rule against a filled tile — its own fill already separates it.
                    divider(hidden: isFilled(visible[index - 1]) || isFilled(session))
                }
                SessionDockTile(
                    session: session, name: session.dockName(among: sessions), now: now,
                    showsDetail: showsDetail, compact: compact,
                    selected: isSelected(.session(session.id))
                ) { toggle(.session(session.id)) }
                .anchorPreference(key: DockTileAnchorKey.self, value: .bounds) { [.session(session.id): $0] }
            }
            if !hidden.isEmpty {
                divider(hidden: (visible.last.map(isFilled) ?? false) || isSelected(.more))
                SessionDockMoreTile(
                    sessions: hidden, all: sessions, compact: compact,
                    selected: isSelected(.more), showsTooltip: !cardShown
                ) { toggle(.more) }
                .anchorPreference(key: DockTileAnchorKey.self, value: .bounds) { [.more: $0] }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .fixedSize()
        .overlayPreferenceValue(DockTileAnchorKey.self) { anchors in
            GeometryReader { proxy in
                cardLayer(anchors: anchors, proxy: proxy)
            }
        }
    }

    private func divider(hidden: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(width: 0.5, height: 24)
            .opacity(hidden ? 0 : 1)
    }

    private func isSelected(_ target: SessionDockSelection) -> Bool {
        cardShown && selection == target
    }

    private func isFilled(_ session: AgentSession) -> Bool {
        session.status.asksForYou || isSelected(.session(session.id))
    }

    // MARK: Card

    /// The open card, centered over its tile and kept within the bar's span, 8pt above it.
    @ViewBuilder
    private func cardLayer(anchors: [SessionDockSelection: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        if let selection, let anchor = anchors[selection] {
            let tile = proxy[anchor]
            let barWidth = proxy.size.width
            // An overlay on a bar-sized clear view, not a ZStack: a ZStack would grow to
            // include the card and pin it back onto the bar's top edge.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) {
                    card(for: selection)
                        .alignmentGuide(.leading) { d in
                            let mid = d.width >= barWidth
                                ? barWidth / 2
                                : min(max(tile.midX, d.width / 2), barWidth - d.width / 2)
                            return d[HorizontalAlignment.center] - mid
                        }
                        .alignmentGuide(.top) { d in d[.bottom] + 8 }
                        .opacity(cardShown ? 1 : 0)
                        .scaleEffect(cardShown ? 1 : 0.97, anchor: .bottom)
                        .offset(y: cardShown ? 0 : 6)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .onHover { overCard = $0; pointerMoved() }
                        .allowsHitTesting(cardShown)
                }
        }
    }

    @ViewBuilder
    private func card(for selection: SessionDockSelection) -> some View {
        switch selection {
        case .session(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                SessionDetailCard(session: session, name: session.dockName(among: sessions), now: now)
            }
        case .more:
            if !hidden.isEmpty {
                MoreSessionsCard(sessions: hidden, all: sessions, now: now)
            }
        }
    }

    // MARK: Open / close

    private func toggle(_ target: SessionDockSelection) {
        if selection == target && cardShown {
            close()
            return
        }
        generation += 1
        if selection == nil {
            // Mount at rest first, then animate in on the next turn — a removal transition
            // would hard-cut in the overlay window, so the card fades by explicit opacity.
            selection = target
            DispatchQueue.main.async {
                withAnimation(Constants.Anim.spring) { cardShown = true }
            }
        } else {
            withAnimation(motion) {
                selection = target
                cardShown = true
            }
        }
    }

    private func close() {
        generation += 1
        let closing = generation
        withAnimation(motion) { cardShown = false }
        // Unmount once the fade is done, unless something reopened it meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard closing == generation else { return }
            selection = nil
        }
    }

    /// Close shortly after the pointer leaves both the dock and the card — long enough to
    /// travel from a tile up into its card without it vanishing.
    private func pointerMoved() {
        guard selection != nil, !overDock, !overCard else { return }
        let pending = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pending == generation, !overDock, !overCard, selection != nil else { return }
            close()
        }
    }
}

private struct DockTileAnchorKey: PreferenceKey {
    static var defaultValue: [SessionDockSelection: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [SessionDockSelection: Anchor<CGRect>],
                       nextValue: () -> [SessionDockSelection: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Tiles

/// Badge, then the session's name over "<state> · <detail>". A session waiting on you gets
/// a faint fill in its own tint, concentric with the bar (8 = 12 − 4); hover and the open
/// card deepen it.
private struct SessionDockTile: View {
    let session: AgentSession
    let name: String
    let now: Date
    let showsDetail: Bool
    let compact: Bool
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: AgentSessionStatus { session.status }

    private var statusLine: Text {
        let state = Text(status.label).foregroundStyle(status.tint)
        guard showsDetail else { return state }
        return state + Text(" \u{00B7} \(session.detail(now: now))").foregroundStyle(.white.opacity(0.5))
    }

    private var fill: Color {
        if status.asksForYou { return status.tint.opacity(selected ? 0.18 : (hovering ? 0.14 : 0.1)) }
        return .white.opacity(selected ? 0.08 : (hovering ? 0.05 : 0))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SessionStatusBadge(status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.lockLabel)
                        .tracking(0.3)
                        .foregroundStyle(.white.opacity(0.85))
                    statusLine
                        .font(.lockCaption)
                        .tracking(0.5)
                }
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: showsDetail ? 112 : 0, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 4 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Constants.Anim.quick, value: hovering)
        .accessibilityLabel(session.accessibilityLabel(now: now, name: name))
        .accessibilityHint("Shows details")
    }
}

/// Stands in for the fifth-and-later sessions: a quiet disc reading "+N". Hover lists their
/// names; a click opens them as a card.
private struct SessionDockMoreTile: View {
    let sessions: [AgentSession]
    let all: [AgentSession]
    let compact: Bool
    let selected: Bool
    let showsTooltip: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var names: String {
        AgentSession.middleTruncated(sessions.map { $0.dockName(among: all) }.joined(separator: ", "), to: 48)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(selected || hovering ? 0.1 : 0.06))
                Circle()
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                Text("+\(sessions.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(selected || hovering ? 0.85 : 0.6))
            }
            .frame(width: 28, height: 28)
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 4 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(selected ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Constants.Anim.quick, value: hovering)
        .overlay(alignment: .top) {
            DockTooltip(text: names)
                .alignmentGuide(.top) { $0[.bottom] + 12 }
                .opacity(hovering && showsTooltip ? 1 : 0)
                .animation(reduceMotion ? nil : Constants.Anim.quick, value: hovering && showsTooltip)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("\(sessions.count) more sessions")
        .accessibilityHint("Shows them")
    }
}

// MARK: - Hover label and cards

/// A small dark label above the "+N" tile — drawn in-view because a system tooltip window
/// would open beneath the shielding-level overlay.
private struct DockTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.lockCaption)
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.dockCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

/// One session in full: its name (and folder, when the name is a title), then status,
/// subagents and timing.
private struct SessionDetailCard: View {
    let session: AgentSession
    let name: String
    let now: Date

    private var status: AgentSessionStatus { session.status }

    /// "needs you for 3m" / "working for 12m", but "done 4m ago" / "error just now".
    private var statusValue: Text {
        let state = Text(status.label).foregroundStyle(status.tint)
        let since: String
        switch status {
        case .done, .error: since = " \(AgentSession.ago(session.statusSince, now: now))"
        default: since = " for \(AgentSession.shortAge(now.timeIntervalSince(session.statusSince)))"
        }
        return state + Text(since).foregroundStyle(.white.opacity(0.75))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SessionStatusBadge(status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle ?? name)
                        .font(.lockLabel)
                        .tracking(0.3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // The folder's name only — never its path, which carries the username.
                    if session.displayTitle != nil {
                        Text(AgentSession.middleTruncated(session.folderName, to: 40))
                            .font(.lockCaption)
                            .tracking(0.5)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    key("Status")
                    statusValue
                }
                GridRow {
                    key("Subagents")
                    value(session.subagentSummary)
                }
                GridRow {
                    key("Started")
                    value(AgentSession.ago(session.startedAt, now: now))
                }
                GridRow {
                    key("Last activity")
                    value(AgentSession.ago(session.updatedAt, now: now))
                }
            }
            .font(.lockCaption)
            .tracking(0.5)
            .lineLimit(1)
        }
        .padding(16)
        .frame(width: 272, alignment: .leading)
        .dockCardSurface()
        .accessibilityElement(children: .combine)
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.4))
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.75))
    }
}

/// The sessions behind "+N", one row each. Scrolling is blocked while locked, so it lists
/// at most eight and counts the rest.
private struct MoreSessionsCard: View {
    let sessions: [AgentSession]
    let all: [AgentSession]
    let now: Date

    private let maxRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(sessions.count) more sessions")
                .font(.lockCaption)
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.45))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(sessions.prefix(maxRows)) { session in
                    let name = session.dockName(among: all)
                    HStack(spacing: 12) {
                        SessionStatusBadge(status: session.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.lockLabel)
                                .tracking(0.3)
                                .foregroundStyle(.white.opacity(0.85))
                            (Text(session.status.label).foregroundStyle(session.status.tint)
                                + Text(" \u{00B7} \(session.detail(now: now))").foregroundStyle(.white.opacity(0.5)))
                                .font(.lockCaption)
                                .tracking(0.5)
                        }
                        .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(session.accessibilityLabel(now: now, name: name))
                }
            }

            if sessions.count > maxRows {
                Text("and \(sessions.count - maxRows) more")
                    .font(.lockCaption)
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(16)
        .frame(width: 272, alignment: .leading)
        .dockCardSurface()
    }
}

extension Color {
    /// Near-opaque canvas (#0E0E11) — hover labels and cards sit over the lock-screen text,
    /// so they stay legible instead of showing it through.
    fileprivate static let dockCard = Color(.sRGB, red: 0.055, green: 0.055, blue: 0.067, opacity: 0.97)
}

extension View {
    /// The detail card's surface: dark canvas, hairline, and a soft contact shadow.
    fileprivate func dockCardSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}
