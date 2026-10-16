import Foundation

/// Which agent sessions are active right now, tracked from hook events, so "Sleep when
/// agents finish" can tell when the last one is done. Also compiled into the CLI, so the
/// activity wire format lives in one place. Keep this file Foundation-only.
///
/// Activity reports are a separate distributed notification from pings, sent by
/// `lockpaw activity`. A turn starting or a tool finishing must never glow the lock
/// screen, and an app that doesn't know them simply ignores them.
///
/// Only agents with turn-start and tool hooks can be tracked: Claude Code
/// (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SessionEnd`) and Gemini CLI
/// (`BeforeAgent`, `BeforeTool`, `AfterTool`, `SessionEnd`). Codex, Cursor, Copilot and
/// Aider only say when a turn finishes.
struct AgentActivity {
    enum Event: Equatable {
        /// A turn started.
        case turnStarted
        /// A tool call started (a command, a subagent…). Held open until it finishes.
        case toolStarted
        /// A tool call finished: a sign of life, and one fewer open call.
        case toolFinished
        /// The agent is blocked on the user (a permission prompt, a question). Holds the
        /// Mac awake: the glow that says so is the one signal Lockpaw exists to show.
        case waiting
        /// The turn ended: finished, failed, or stopped on a rate limit.
        case finished
        /// The session closed.
        case ended
    }

    /// One decoded activity report.
    struct Report: Equatable {
        let agent: String?
        let sessionID: String
        let event: Event
    }

    /// Distributed notification `lockpaw activity` posts.
    static let distributedName = "com.eriknielsen.lockpaw.activity"

    /// A session with nothing open and no sign of life for this long counts as done:
    /// Claude Code sends no `Stop` when a turn is interrupted with Esc, and a killed
    /// process sends no `SessionEnd`. Between tool calls there is only the model thinking,
    /// so a live turn never goes this long without a report.
    static let staleAfter: TimeInterval = 30 * 60

    /// The same, for a session with a tool call open or waiting on the user. A long build,
    /// test run or training job reports nothing until it ends, and sleeping under it loses
    /// work, so this leans towards staying awake. It still has an end, because a call
    /// whose finish never arrived (a turn interrupted mid-command) would otherwise hold
    /// the Mac awake for good.
    static let busyStaleAfter: TimeInterval = 12 * 60 * 60

    // MARK: - Mapping

    static func event(forHook hookEvent: String?) -> Event? {
        switch hookEvent {
        case "UserPromptSubmit", "BeforeAgent": return .turnStarted
        case "PreToolUse", "BeforeTool": return .toolStarted
        case "PostToolUse", "AfterTool": return .toolFinished
        case "SessionEnd": return .ended
        default: return nil
        }
    }

    /// What a ping says about its session. Only a turn that really ended lets the Mac
    /// sleep; a session waiting for the user holds it awake.
    static func event(for kind: AgentPing.Kind) -> Event? {
        switch kind {
        case .finished, .failed, .rateLimited: return .finished
        case .permission, .needsInput: return .waiting
        case .attention: return nil
        }
    }

    // MARK: - CLI side

    /// What `lockpaw activity` sends: the agent, the hook event and the session id. Nothing
    /// else leaves the hook. Nil when the payload isn't a tracked event or has no session:
    /// there is nothing to track then. That includes a payload too big or too slow to parse
    /// (`PostToolUse` carries the tool's output), which costs one report and nothing more.
    static func userInfo(arguments: [String], stdinPayload: [String: Any]) -> [String: String]? {
        guard let hookEvent = stdinPayload[AgentPing.Key.hookEvent] as? String,
              event(forHook: hookEvent) != nil,
              let session = stdinPayload[AgentPing.Key.sessionID] as? String, !session.isEmpty else { return nil }
        var info = [AgentPing.Key.hookEvent: hookEvent, AgentPing.Key.sessionID: session]
        if let index = arguments.firstIndex(of: "--agent"), arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            info[AgentPing.Key.agent] = arguments[index + 1]
        }
        return info
    }

    // MARK: - App side

    static func report(from userInfo: [AnyHashable: Any]?) -> Report? {
        guard let hookEvent = userInfo?[AgentPing.Key.hookEvent] as? String,
              let event = event(forHook: hookEvent),
              let session = userInfo?[AgentPing.Key.sessionID] as? String, !session.isEmpty else { return nil }
        let agent = (userInfo?[AgentPing.Key.agent] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Report(agent: agent.map(AgentPing.displayName(forAgent:)), sessionID: session, event: event)
    }

    // MARK: - Tracking

    private struct Session {
        var lastSeen: Date
        /// Tool calls started and not yet finished. Parallel calls and subagents nest, so a
        /// count rather than a flag. A finish that never arrives is cleared by the turn's
        /// end or the next turn's start.
        var openTools = 0
        var waiting = false

        var busy: Bool { openTools > 0 || waiting }
    }

    /// Active sessions, keyed by agent and session id.
    private var sessions: [String: Session] = [:]

    mutating func record(_ event: Event, agent: String?, sessionID: String?, at now: Date) {
        guard let sessionID else { return }
        let key = "\(agent ?? "-")/\(sessionID)"
        var session = sessions[key] ?? Session(lastSeen: now)
        session.lastSeen = now
        switch event {
        case .turnStarted:
            session.openTools = 0
            session.waiting = false
        case .toolStarted:
            session.openTools += 1
            session.waiting = false
        case .toolFinished:
            session.openTools = max(0, session.openTools - 1)
            session.waiting = false
        case .waiting:
            session.waiting = true
        case .finished, .ended:
            sessions[key] = nil
            prune(at: now)
            return
        }
        sessions[key] = session
        prune(at: now)
    }

    mutating func record(_ report: Report, at now: Date) {
        record(report.event, agent: report.agent, sessionID: report.sessionID, at: now)
    }

    /// Sessions that hold the Mac awake: working, running a tool, or waiting on the user.
    func activeSessions(at now: Date) -> Int {
        sessions.values.filter { Self.isLive($0, at: now) }.count
    }

    private mutating func prune(at now: Date) {
        sessions = sessions.filter { Self.isLive($0.value, at: now) }
    }

    private static func isLive(_ session: Session, at now: Date) -> Bool {
        now.timeIntervalSince(session.lastSeen) < (session.busy ? busyStaleAfter : staleAfter)
    }
}
