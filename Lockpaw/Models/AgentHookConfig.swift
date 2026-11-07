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
        /// Someone else's `notify` was set. It now runs right after Lockpaw's ping, with the
        /// same payload. `original` is their command, as it was.
        case chained(String, original: [String])
        /// A `notify` (or a file) Lockpaw can't read safely. Never rewritten.
        case unreadable
    }

    /// Put lockpaw's `notify` into a Codex config.toml as a **top-level** key. TOML assigns a
    /// key to the most recent `[table]` header above it, and real configs end with one
    /// (`[mcp_servers.x]`, `[profiles.y]`), so appending to the file would have written
    /// `mcp_servers.x.notify`, which Codex ignores. So only the top level (before the first
    /// header) is searched, and a new line goes at its end.
    ///
    /// Codex runs one `notify` command. When another tool already owns it, skipping left
    /// Lockpaw silent (#45), and replacing it would break that tool. So Lockpaw chains:
    /// `notify = [lockpaw, "ping", "--agent", "codex", "--", <their command>]`. The ping
    /// runs, then hands off to their command with Codex's payload still last. Only the
    /// `notify` statement changes. Comments and every other line stay as they were.
    static func mergingCodexNotify(into contents: String, command: [String]) -> CodexNotifyMerge {
        guard let scan = CodexConfig.scan(contents) else { return .unreadable }
        let chars = Array(contents)

        if let notify = scan.notify {
            guard let argv = notify.argv else { return .unreadable }
            let wanted: [String]
            if argv.isEmpty {
                wanted = command
            } else if CodexConfig.isLockpawNotify(argv) {
                let chained = CodexConfig.chainedCommand(in: argv)
                wanted = chained.isEmpty ? command : command + [CodexConfig.chainSeparator] + chained
                if argv == wanted { return .unchanged }
            } else {
                wanted = command + [CodexConfig.chainSeparator] + argv
            }
            let text = String(chars[..<notify.range.lowerBound])
                + CodexConfig.notifyLine(wanted)
                + String(chars[notify.range.upperBound...])
            if argv.isEmpty { return .added(text) }
            return CodexConfig.isLockpawNotify(argv) ? .upgraded(text) : .chained(text, original: argv)
        }

        let line = CodexConfig.notifyLine(command)
        if scan.firstTable == chars.count {
            var result = contents
            if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
            return .added(result + line + "\n")
        }
        // Before the first table, after the last top-level key, with a blank line before the
        // header. A comment right above the header belongs to it, so the line goes above that.
        var lines = String(chars[..<scan.firstTable]).components(separatedBy: "\n")
        // The prefix ends at the start of the header's line, so its last element is empty.
        if lines.last == "" { lines.removeLast() }
        let isBlank = { (text: String) in text.trimmingCharacters(in: .whitespaces).isEmpty }
        let isComment = { (text: String) in text.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var insertAt = lines.count
        while insertAt > 0, isComment(lines[insertAt - 1]) { insertAt -= 1 }
        while insertAt > 0, isBlank(lines[insertAt - 1]) { insertAt -= 1 }
        let blankFollows = insertAt < lines.count && isBlank(lines[insertAt])
        lines.insert(contentsOf: blankFollows ? [line] : [line, ""], at: insertAt)
        return .added(lines.joined(separator: "\n") + "\n" + String(chars[scan.firstTable...]))
    }
}
