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
        hookFields: [String: Any] = [:]
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
                    if let cmd = inner[h]["command"] as? String, isLockpawPingCommand(cmd) {
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
