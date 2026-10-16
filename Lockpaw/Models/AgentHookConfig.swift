import Foundation

/// Pure merge logic for the hook configs `lockpaw install-hook` writes. Lives with the
/// app's models (and is compiled into the CLI too) so the unit tests can reach it.
enum AgentHookConfig {
    /// Claude Code `Notification` types worth a glow. Without a matcher every
    /// notification pings, including ones that need nothing from the user
    /// (`auth_success`, a quota wait that resumed by itself, elicitation bookkeeping).
    /// `idle_prompt` is included and decodes as *finished*: it fires a minute after a
    /// turn ends with no reply, which covers a `Stop` that landed just before the screen
    /// was locked (pings while unlocked are dropped). `PingGate` keeps it from reading as
    /// a second event when `Stop` already announced the same session.
    static let claudeNotificationMatcher = [
        "permission_prompt",
        "idle_prompt",
        "elicitation_dialog",
        "elicitation_url_dialog",
        "agent_needs_input",
        "agent_completed",
        "quota_auto_resume_stale",
        "quota_auto_resume_disabled",
    ].joined(separator: "|")

    /// Matches any hook that runs a lockpaw ping, in whatever form a past version wrote it.
    static func isLockpawPingCommand(_ command: String) -> Bool {
        command.contains("lockpaw") && command.contains("ping")
    }

    /// Matches the hook that runs `lockpaw activity` ("Sleep when agents finish").
    static func isLockpawActivityCommand(_ command: String) -> Bool {
        command.contains("lockpaw") && command.contains("activity")
    }

    /// Claude Code events reported by `lockpaw activity`: a prompt starts a turn, a tool
    /// call is open from its start to its finish, and the session closing ends it. Only
    /// installed while "Sleep when agents finish" is on: they run a lockpaw process on
    /// every tool call, which nobody else should pay for.
    static let claudeActivityEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionEnd"]
    /// Gemini CLI's equivalents.
    static let geminiActivityEvents = ["BeforeAgent", "BeforeTool", "AfterTool", "SessionEnd"]

    /// Whether a Claude-style config already runs one of lockpaw's hooks — for the ping,
    /// "is this agent connected?".
    static func containsHook(in root: [String: Any], isOwnCommand: (String) -> Bool = isLockpawPingCommand) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                    (hook["command"] as? String).map(isOwnCommand) ?? false
                }
            }
        }
    }

    /// Take lockpaw's own hooks out of a Claude-style `hooks` object, leaving every foreign
    /// hook where it was. A group left empty goes, then an event left empty, then `hooks`.
    static func removingHooks(
        from root: [String: Any],
        events: [String],
        isOwnCommand: (String) -> Bool
    ) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = inner.filter { !((($0["command"] as? String).map(isOwnCommand)) ?? false) }
                guard !remaining.isEmpty else { return nil }
                var group = group
                group["hooks"] = remaining
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    /// Merge a lockpaw ping into a Claude Code-style `hooks` object — the schema Gemini
    /// CLI adopted too: each event maps to an array of groups, each group holding a
    /// `hooks` array of {type, command} entries. Upgrades any existing lockpaw entry in
    /// place (older versions wrote a bare `lockpaw ping`, which silently fails when
    /// ~/.local/bin isn't on PATH); never touches foreign hooks. A matcher is only ever
    /// set on a group that holds nothing but lockpaw's own hook, so it cannot narrow
    /// someone else's.
    static func mergingPingHook(
        into root: [String: Any],
        events: [String],
        command: String,
        matchers: [String: String] = [:],
        hookFields: [String: Any] = [:],
        isOwnCommand: (String) -> Bool = isLockpawPingCommand
    ) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var present = false
            for g in groups.indices {
                guard var inner = groups[g]["hooks"] as? [[String: Any]] else { continue }
                var ownsGroup = !inner.isEmpty
                for h in inner.indices {
                    if let cmd = inner[h]["command"] as? String, isOwnCommand(cmd) {
                        inner[h]["command"] = command
                        inner[h].merge(hookFields) { _, new in new }
                        present = true
                    } else {
                        ownsGroup = false
                    }
                }
                groups[g]["hooks"] = inner
                if ownsGroup, let matcher = matchers[event] { groups[g]["matcher"] = matcher }
            }
            if !present {
                let base: [String: Any] = ["type": "command", "command": command]
                let hook = base.merging(hookFields) { _, new in new }
                var group: [String: Any] = ["hooks": [hook]]
                if let matcher = matchers[event] { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    enum CodexNotifyMerge: Equatable {
        case added(String)
        case upgraded(String)
        case unchanged
        /// Someone else's `notify` is already set; never clobbered.
        case foreign
    }

    /// Put lockpaw's `notify = [...]` into a Codex config.toml as a **top-level** key. TOML
    /// assigns a key to the most recent `[table]` header above it, and real configs end with
    /// one (`[mcp_servers.x]`, `[profiles.y]`), so appending to the file would have written
    /// `mcp_servers.x.notify`, which Codex ignores. So only the top-level region (before
    /// the first header) is searched, and a new line goes at its end.
    static func mergingCodexNotify(into contents: String, line: String) -> CodexNotifyMerge {
        var lines = contents.components(separatedBy: "\n")
        let isHeader = { (text: String) in text.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let firstHeader = lines.firstIndex(where: isHeader) ?? lines.count
        let isNotify = { (text: String) in
            text.range(of: #"^\s*notify\s*="#, options: .regularExpression) != nil
        }

        if let existing = lines[..<firstHeader].firstIndex(where: isNotify) {
            guard isLockpawPingCommand(lines[existing]) else { return .foreign }
            guard lines[existing] != line else { return .unchanged }
            lines[existing] = line
            return .upgraded(lines.joined(separator: "\n"))
        }

        if firstHeader == lines.count {
            var result = contents
            if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
            return .added(result + line + "\n")
        }
        // Before the first table, after any top-level keys, with a blank line before the header.
        var insertAt = firstHeader
        while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        let blankAlreadyFollows = insertAt < firstHeader
        lines.insert(contentsOf: blankAlreadyFollows ? [line] : [line, ""], at: insertAt)
        return .added(lines.joined(separator: "\n"))
    }
}
