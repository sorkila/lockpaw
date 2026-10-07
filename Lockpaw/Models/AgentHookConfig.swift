import Foundation

/// Pure merge logic for the hook configs `lockpaw install-hook` writes. Lives with the
/// app's models (and is compiled into the CLI too) so the unit tests can reach it.
enum AgentHookConfig {
    /// Claude Code `Notification` types worth a glow. Without a matcher every
    /// notification pings, including ones that need nothing from the user
    /// (`auth_success`, a quota wait that resumed by itself, elicitation bookkeeping).
    /// `idle_prompt` is included and decodes as *finished*: it fires a minute after a
    /// turn ends with no reply, which covers a `Stop` that landed just before the screen
    /// was locked (pings while unlocked are dropped). Per-session de-duplication on the
    /// lock screen keeps it from reading as a second event.
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
}
