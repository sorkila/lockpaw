import Foundation

/// One agent's request for attention, decoded from the payload its hook handed to
/// `lockpaw ping`. Also compiled into the CLI target, so the wire format lives in
/// one place — keep this file Foundation-only.
struct AgentPing: Equatable {
    enum Kind: Equatable {
        case finished
        case permission
        case needsInput
        case rateLimited
        case failed
        /// A bare ping with no payload, or an event this build does not recognise.
        case attention

        var verb: String {
            switch self {
            case .finished: return "finished"
            case .permission: return "needs permission"
            case .needsInput: return "needs input"
            case .rateLimited: return "hit a rate limit"
            case .failed: return "stopped on an error"
            case .attention: return "needs you"
            }
        }
    }

    /// userInfo keys of the distributed notification. `agent` comes from the hook
    /// command's `--agent` flag; the rest are hook payload fields, forwarded verbatim.
    enum Key {
        static let agent = "agent"
        static let cwd = "cwd"
        static let hookEvent = "hook_event_name"
        static let notificationType = "notification_type"
        static let error = "error"
        static let sessionID = "session_id"

        static let forwardedFromPayload = [cwd, hookEvent, notificationType, error, sessionID]
    }

    let agent: String?
    let project: String?
    let kind: Kind
    let sessionID: String?
    let receivedAt: Date

    var summary: String {
        let subject = agent ?? "Your agent"
        guard let project else { return "\(subject) \(kind.verb)" }
        return "\(subject) \(kind.verb) in \(project)"
    }

    static func from(userInfo: [AnyHashable: Any]?, now: Date = Date()) -> AgentPing {
        let field = { (key: String) -> String? in
            guard let value = userInfo?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return AgentPing(
            agent: field(Key.agent).map(displayName(forAgent:)),
            project: field(Key.cwd).flatMap(projectName(fromWorkingDirectory:)),
            kind: kind(
                hookEvent: field(Key.hookEvent),
                notificationType: field(Key.notificationType),
                error: field(Key.error)
            ),
            sessionID: field(Key.sessionID),
            receivedAt: now
        )
    }

    /// CLI side: the string fields of a hook payload worth sending, plus the agent flag.
    /// Everything else (transcripts, the assistant's last message) stays in the hook.
    static func userInfo(agent: String?, hookPayload: [String: Any]) -> [String: String] {
        var info: [String: String] = [:]
        if let agent, !agent.isEmpty { info[Key.agent] = agent }
        for key in Key.forwardedFromPayload {
            if let value = hookPayload[key] as? String, !value.isEmpty { info[key] = value }
        }
        return info
    }

    /// Claude Code's events, plus Gemini CLI's `AfterAgent`. `StopFailure` replaces
    /// `Stop` when a turn ends on an API error, and names the error in `error`.
    static func kind(hookEvent: String?, notificationType: String?, error: String?) -> Kind {
        switch hookEvent {
        case "Stop", "AfterAgent":
            return .finished
        case "StopFailure":
            return error == "rate_limit" ? .rateLimited : .failed
        case "Notification":
            switch notificationType {
            case "permission_prompt": return .permission
            case "agent_completed": return .finished
            case nil: return .attention
            default: return .needsInput
            }
        default:
            return .attention
        }
    }

    static func displayName(forAgent agent: String) -> String {
        switch agent.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "cursor": return "Cursor"
        case "copilot": return "Copilot"
        case "aider": return "Aider"
        default: return agent
        }
    }

    static func projectName(fromWorkingDirectory cwd: String) -> String? {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
