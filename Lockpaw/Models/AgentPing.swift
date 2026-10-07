import Foundation

/// One agent's request for attention, decoded from what its hook handed to
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

    /// userInfo keys of the distributed notification.
    enum Key {
        static let agent = "agent"
        /// Basename of the agent's working directory — never the full path, which
        /// carries the username and directory layout, and any process in the login
        /// session can read a distributed notification.
        static let project = "project"
        /// Explicit kind from `--done` / `--waiting` / `--error`, for agents whose
        /// payload doesn't say what happened (Cursor, Copilot, Aider, Codex notify).
        static let kind = "kind"
        static let hookEvent = "hook_event_name"
        static let notificationType = "notification_type"
        static let error = "error"
        static let sessionID = "session_id"
        /// Read for robustness only; the CLI sends `project` instead.
        static let legacyCwd = "cwd"

        /// Hook payload fields forwarded verbatim. Everything else — transcripts, the
        /// assistant's last message, tool input — stays in the hook.
        static let forwardedFromPayload = [hookEvent, notificationType, error, sessionID]
    }

    /// Values of `Key.kind`, one per `lockpaw ping` flag.
    enum KindFlag: String, CaseIterable {
        case done, waiting, error

        var flag: String { "--\(rawValue)" }
    }

    let agent: String?
    let project: String?
    let kind: Kind
    let sessionID: String?
    let receivedAt: Date

    /// What the notification and the lock screen say. Project names are opt-in on the
    /// lock screen (anyone walking past can read it), so callers choose.
    func summary(includingProject: Bool = true) -> String {
        let subject = agent ?? "Your agent"
        guard includingProject, let project else { return "\(subject) \(kind.verb)" }
        return "\(subject) \(kind.verb) in \(project)"
    }

    static func from(userInfo: [AnyHashable: Any]?, now: Date = Date()) -> AgentPing {
        let field = { (key: String) -> String? in
            guard let value = userInfo?[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return AgentPing(
            agent: field(Key.agent).map(displayName(forAgent:)),
            project: field(Key.project) ?? field(Key.legacyCwd).flatMap(projectName(fromWorkingDirectory:)),
            kind: kind(
                flag: field(Key.kind).flatMap(KindFlag.init(rawValue:)),
                hookEvent: field(Key.hookEvent),
                notificationType: field(Key.notificationType),
                error: field(Key.error)
            ),
            sessionID: field(Key.sessionID),
            receivedAt: now
        )
    }

    // MARK: - CLI side

    /// Everything `lockpaw ping` sends, from its arguments and the payload the hook piped
    /// in. Pure, so the CLI's parsing is covered by the app's unit tests.
    ///
    /// Codex `notify` runs the program argv-style with stdin at /dev/null and appends its
    /// JSON payload as the last argument (`type`, `thread-id`, `cwd`, plus message fields
    /// that are never read here), so argv is checked for that shape too.
    static func userInfo(arguments: [String], stdinPayload: [String: Any]) -> [String: String] {
        var info: [String: String] = [:]
        if let agent = value(after: "--agent", in: arguments), !agent.isEmpty { info[Key.agent] = agent }

        var payload = stdinPayload
        if payload.isEmpty, let codex = codexNotifyPayload(in: arguments) {
            if codex["type"] as? String == "agent-turn-complete" { info[Key.kind] = KindFlag.done.rawValue }
            if let thread = codex["thread-id"] as? String { payload[Key.sessionID] = thread }
            if let cwd = codex["cwd"] as? String { payload[Key.legacyCwd] = cwd }
        }

        for key in Key.forwardedFromPayload {
            if let value = payload[key] as? String, !value.isEmpty { info[key] = value }
        }
        if let cwd = payload[Key.legacyCwd] as? String, let name = projectName(fromWorkingDirectory: cwd) {
            info[Key.project] = name
        }
        // An explicit flag beats anything inferred.
        if let flag = KindFlag.allCases.first(where: { arguments.contains($0.flag) }) {
            info[Key.kind] = flag.rawValue
        }
        return info
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        zip(arguments, arguments.dropFirst()).first { $0.0 == flag }?.1
    }

    private static func codexNotifyPayload(in arguments: [String]) -> [String: Any]? {
        guard let last = arguments.last, last.hasPrefix("{"),
              let data = last.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] is String else { return nil }
        return object
    }

    // MARK: - Mapping

    /// An explicit flag wins. Otherwise Claude Code's events, Gemini CLI's (`AfterAgent`,
    /// and `ToolPermission` notifications) and Codex's `PermissionRequest` hook.
    /// `StopFailure` replaces `Stop` when a turn ends on an API error.
    static func kind(flag: KindFlag? = nil, hookEvent: String?, notificationType: String?, error: String?) -> Kind {
        switch flag {
        case .done: return .finished
        case .waiting: return .needsInput
        case .error: return .failed
        case nil: break
        }
        switch hookEvent {
        case "Stop", "AfterAgent":
            return .finished
        case "StopFailure":
            return error == "rate_limit" ? .rateLimited : .failed
        case "PermissionRequest":
            return .permission
        case "Notification":
            switch notificationType {
            case "permission_prompt", "ToolPermission": return .permission
            // `idle_prompt` fires a minute after a turn ends with no reply — the turn is
            // done, so it must not turn a row amber.
            case "agent_completed", "idle_prompt": return .finished
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
