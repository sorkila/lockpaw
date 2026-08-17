import Foundation

// The `lockpaw` command-line tool. Lets AI coding agents (Claude Code, Codex,
// Gemini CLI, Cursor, Copilot CLI, Aider, or anything scriptable) ping Lockpaw so
// the locked screen glows and a notification fires when they need you.
//
// Transport: a DistributedNotificationCenter message — NOT the lockpaw:// URL
// scheme — so a background ping never launches the app when it isn't running.

let pingNotificationName = "com.eriknielsen.lockpaw.ping"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    exit(1)
}

/// Resolve the user's home via $HOME (the convention agent CLIs use to locate their
/// own config), falling back to the account home. NOT homeDirectoryForCurrentUser
/// alone — that ignores $HOME.
func homeDirectory() -> URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

func printUsage() {
    print("""
    lockpaw — tap Lockpaw when your AI agent needs you

    USAGE:
      lockpaw ping                  Signal Lockpaw (locked screen glows + notification)
      lockpaw install-cli           Symlink this tool into your PATH (~/.local/bin)
      lockpaw install-hook <tool>   Wire up an agent. <tool>: claude | codex | gemini |
                                    cursor | copilot | aider
                                    Add --print to show the snippet without writing it.
      lockpaw --help                Show this help

    EXAMPLES:
      lockpaw install-cli
      lockpaw install-hook claude
      lockpaw install-hook codex --print

    Lockpaw stays locked while you're away; ping just lets you know it's time to look.
    """)
}

// MARK: - ping

func sendPing() {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(pingNotificationName),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

// MARK: - install-cli

/// The real on-disk path of this running binary (inside Lockpaw.app), resolving
/// through any symlink it was invoked via so the install target points at the app.
func currentBinaryURL() -> URL? {
    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") {
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
    }
    if let path = Bundle.main.executablePath, path.hasSuffix("lockpaw") {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    return nil
}

/// Create or refresh `~/.local/bin/lockpaw` → this binary. Idempotent; re-running
/// picks up a moved app. Returns the symlink URL.
@discardableResult
func ensureCLISymlink() throws -> URL {
    let fm = FileManager.default
    guard let exec = currentBinaryURL() else {
        throw NSError(domain: "Lockpaw", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not determine the lockpaw binary path."
        ])
    }
    let binDir = homeDirectory().appendingPathComponent(".local/bin", isDirectory: true)
    let link = binDir.appendingPathComponent("lockpaw")
    try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    if (try? link.checkResourceIsReachable()) == true || fm.fileExists(atPath: link.path) {
        try? fm.removeItem(at: link)
    }
    try fm.createSymbolicLink(at: link, withDestinationURL: exec)
    return link
}

func installCLI() {
    let link: URL
    do {
        link = try ensureCLISymlink()
        print("✓ Linked lockpaw → \(link.path)")
    } catch {
        fail("Could not create symlink: \(error.localizedDescription)")
    }

    let binDir = link.deletingLastPathComponent()

    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let onPath = path.split(separator: ":").contains { $0 == binDir.path }
    if onPath {
        print("  You can now run `lockpaw ping` from anywhere.")
    } else {
        print("""

        ⚠️  \(binDir.path) is not on your PATH. Add this to your shell profile
            (~/.zshrc or ~/.bashrc), then restart your shell:
                export PATH="$HOME/.local/bin:$PATH"
        """)
    }
}

// MARK: - install-hook

/// Refresh `<file>.bak` with the current contents, if the file exists.
func backupFile(at url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    let backup = url.appendingPathExtension("bak")
    try? fm.removeItem(at: backup)
    try? fm.copyItem(at: url, to: backup)
}

func writeJSON(_ object: [String: Any], to url: URL, label: String) {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        backupFile(at: url)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
        print("✓ Updated \(label) config at \(url.path)")
    } catch {
        fail("Could not write \(label) config: \(error.localizedDescription)")
    }
}

func readJSONObject(at url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

/// Claude Code's config directory: $CLAUDE_CONFIG_DIR if set (users running multiple
/// profiles point it elsewhere), otherwise ~/.claude.
func claudeConfigDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }
    return homeDirectory().appendingPathComponent(".claude", isDirectory: true)
}

/// The hook command we write. `$HOME/.local/bin/lockpaw` rather than bare `lockpaw`
/// so the hook works even when `~/.local/bin` isn't on the agent's PATH; the shell
/// that runs hook commands expands `$HOME`. The symlink (not the app bundle path)
/// keeps the hook valid when the app moves or updates.
let claudePingCommand = "\"$HOME/.local/bin/lockpaw\" ping"

/// Matches any hook that runs a lockpaw ping, in whatever form a past version wrote it.
func isLockpawPingCommand(_ command: String) -> Bool {
    command.contains("lockpaw") && command.contains("ping")
}

/// The command points at the ~/.local/bin symlink; bail out if it can't be created.
func requireCLISymlink() {
    do {
        try ensureCLISymlink()
    } catch {
        fail("Could not install the lockpaw command: \(error.localizedDescription)")
    }
}

/// Merge a lockpaw ping into a Claude Code-style `hooks` object — the schema Gemini
/// CLI adopted too: each event maps to an array of groups, each group holding a
/// `hooks` array of {type, command} entries. Upgrades any existing lockpaw entry in
/// place (older versions wrote a bare `lockpaw ping`, which silently fails when
/// ~/.local/bin isn't on PATH); never touches foreign hooks.
func mergingPingHook(into root: [String: Any], events: [String]) -> [String: Any] {
    var root = root
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for event in events {
        var groups = hooks[event] as? [[String: Any]] ?? []
        var present = false
        for g in groups.indices {
            guard var inner = groups[g]["hooks"] as? [[String: Any]] else { continue }
            for h in inner.indices {
                if let cmd = inner[h]["command"] as? String, isLockpawPingCommand(cmd) {
                    inner[h]["command"] = claudePingCommand
                    present = true
                }
            }
            groups[g]["hooks"] = inner
        }
        if !present {
            groups.append(["hooks": [["type": "command", "command": claudePingCommand]]])
        }
        hooks[event] = groups
    }
    root["hooks"] = hooks
    return root
}

func claudeStyleSnippet(path: String, events: [String]) -> String {
    let escaped = claudePingCommand.replacingOccurrences(of: "\"", with: "\\\"")
    let width = events.map(\.count).max() ?? 0
    let lines = events.map { event in
        let padding = String(repeating: " ", count: width - event.count)
        return "    \"\(event)\": \(padding)[{ \"hooks\": [{ \"type\": \"command\", \"command\": \"\(escaped)\" }] }]"
    }
    return """
    Add to \(path):

      "hooks": {
    \(lines.joined(separator: ",\n"))
      }
    """
}

func installClaudeHook(printOnly: Bool) {
    let url = claudeConfigDirectory().appendingPathComponent("settings.json")
    let events = ["Notification", "Stop"]
    if printOnly { print(claudeStyleSnippet(path: url.path, events: events)); return }
    requireCLISymlink()
    writeJSON(mergingPingHook(into: readJSONObject(at: url), events: events),
              to: url, label: "Claude Code")
}

func installCodexHook(printOnly: Bool) {
    // Codex executes `notify` as an argv array (no shell), so the path must be
    // literal — the ~/.local/bin symlink keeps it stable across app moves/updates.
    let linkPath = homeDirectory().appendingPathComponent(".local/bin/lockpaw").path
    let line = "notify = [\"\(linkPath)\", \"ping\"]"
    if printOnly {
        print("Add to ~/.codex/config.toml (user-level — `notify` is ignored in project configs):\n\n  \(line)")
        return
    }

    requireCLISymlink()

    let fm = FileManager.default
    let url = homeDirectory().appendingPathComponent(".codex/config.toml")
    var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

    if let existing = contents.range(of: #"(?m)^\s*notify\s*=.*$"#, options: .regularExpression) {
        // Upgrade an older lockpaw notify in place; never clobber someone else's.
        if isLockpawPingCommand(String(contents[existing])) {
            if contents[existing] != Substring(line) {
                contents.replaceSubrange(existing, with: line)
                backupFile(at: url)
                do {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                    print("✓ Updated notify hook in Codex config at \(url.path)")
                } catch {
                    fail("Could not write Codex config: \(error.localizedDescription)")
                }
            } else {
                print("✓ Codex config already routes notify through Lockpaw.")
            }
            return
        }
        print("""
        ⚠️  ~/.codex/config.toml already defines `notify` — leaving it untouched.
        To route Codex through Lockpaw, set it to:
            \(line)
        """)
        return
    }

    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        backupFile(at: url)
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += line + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        print("✓ Added notify hook to Codex config at \(url.path)")
    } catch {
        fail("Could not write Codex config: \(error.localizedDescription)")
    }
}

func installGeminiHook(printOnly: Bool) {
    // Gemini CLI adopted Claude Code's hook schema (stable since mid-2026), so the
    // same merge applies. AfterAgent fires once per turn after the final response;
    // Notification fires on system alerts like tool-permission prompts.
    let url = homeDirectory().appendingPathComponent(".gemini/settings.json")
    let events = ["Notification", "AfterAgent"]
    if printOnly { print(claudeStyleSnippet(path: url.path, events: events)); return }
    requireCLISymlink()
    writeJSON(mergingPingHook(into: readJSONObject(at: url), events: events),
              to: url, label: "Gemini CLI")
}

func installCursorHook(printOnly: Bool) {
    // Cursor's hooks.json is flat — each event maps straight to [{command}]; `stop`
    // fires when the agent loop completes (in the IDE and the CLI). Cursor doesn't
    // document a shell guarantee for hook commands, so the command uses the literal
    // symlink path: no $HOME expansion needed, and macOS home paths have no spaces.
    let linkPath = homeDirectory().appendingPathComponent(".local/bin/lockpaw").path
    let command = "\(linkPath) ping"
    let url = homeDirectory().appendingPathComponent(".cursor/hooks.json")
    let snippet = """
    Add to \(url.path):

      { "version": 1, "hooks": { "stop": [{ "command": "\(command)" }] } }
    """
    if printOnly { print(snippet); return }
    requireCLISymlink()

    var root = readJSONObject(at: url)
    if root["version"] == nil { root["version"] = 1 }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var groups = hooks["stop"] as? [[String: Any]] ?? []
    var present = false
    for g in groups.indices {
        if let cmd = groups[g]["command"] as? String, isLockpawPingCommand(cmd) {
            groups[g]["command"] = command
            present = true
        }
    }
    if !present { groups.append(["command": command]) }
    hooks["stop"] = groups
    root["hooks"] = hooks
    writeJSON(root, to: url, label: "Cursor")
}

/// Copilot CLI's hooks directory: $COPILOT_HOME/hooks if set, else ~/.copilot/hooks.
func copilotHooksDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["COPILOT_HOME"], !dir.isEmpty {
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
    }
    return homeDirectory().appendingPathComponent(".copilot/hooks", isDirectory: true)
}

func installCopilotHook(printOnly: Bool) {
    // Copilot CLI loads every *.json in its hooks directory, so Lockpaw owns a whole
    // file — nothing foreign to merge with or clobber, and rewriting it is idempotent.
    // agentStop = turn finished; notification = permission prompts and other alerts.
    // The `bash` key guarantees a shell on macOS, so the $HOME form works.
    let url = copilotHooksDirectory().appendingPathComponent("lockpaw.json")
    let escaped = claudePingCommand.replacingOccurrences(of: "\"", with: "\\\"")
    let snippet = """
    Write \(url.path):

      {
        "version": 1,
        "hooks": {
          "agentStop":    [{ "type": "command", "bash": "\(escaped)" }],
          "notification": [{ "type": "command", "bash": "\(escaped)" }]
        }
      }
    """
    if printOnly { print(snippet); return }
    requireCLISymlink()
    let hook: [String: Any] = ["type": "command", "bash": claudePingCommand]
    writeJSON(
        ["version": 1, "hooks": ["agentStop": [hook], "notification": [hook]]],
        to: url, label: "Copilot CLI"
    )
}

func installAiderHook(printOnly: Bool) {
    // Aider has a single notification moment — the LLM finished and awaits input —
    // configured in ~/.aider.conf.yml. The docs don't promise notifications-command
    // implies notifications, so write both keys. Literal symlink path, same
    // reasoning as Cursor.
    let linkPath = homeDirectory().appendingPathComponent(".local/bin/lockpaw").path
    let enableLine = "notifications: true"
    let commandLine = "notifications-command: \"\(linkPath) ping\""
    let url = homeDirectory().appendingPathComponent(".aider.conf.yml")
    if printOnly {
        print("Add to \(url.path):\n\n  \(enableLine)\n  \(commandLine)")
        return
    }
    requireCLISymlink()

    var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var changed = false

    if let existing = contents.range(of: #"(?m)^\s*notifications-command\s*:.*$"#, options: .regularExpression) {
        // Upgrade an older lockpaw command in place; never clobber someone else's.
        guard isLockpawPingCommand(String(contents[existing])) else {
            print("""
            ⚠️  \(url.path) already defines `notifications-command` — leaving it untouched.
            To route Aider through Lockpaw, set it to:
                \(commandLine)
            """)
            return
        }
        if contents[existing] != Substring(commandLine) {
            contents.replaceSubrange(existing, with: commandLine)
            changed = true
        }
    } else {
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += commandLine + "\n"
        changed = true
    }

    if let enabled = contents.range(of: #"(?m)^\s*notifications\s*:.*$"#, options: .regularExpression) {
        if contents[enabled] != Substring(enableLine) {
            contents.replaceSubrange(enabled, with: enableLine)
            changed = true
        }
    } else {
        contents = contents.replacingOccurrences(of: commandLine, with: enableLine + "\n" + commandLine)
        changed = true
    }

    guard changed else {
        print("✓ Aider config already routes notifications through Lockpaw.")
        return
    }
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        backupFile(at: url)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        print("✓ Updated Aider config at \(url.path)")
    } catch {
        fail("Could not write Aider config: \(error.localizedDescription)")
    }
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "ping":
    // Ignore any trailing args — Codex appends a JSON payload to the notify program.
    sendPing()
case "install-cli":
    installCLI()
case "install-hook":
    guard args.count >= 2 else {
        fail("Usage: lockpaw install-hook <claude|codex|gemini|cursor|copilot|aider> [--print]")
    }
    let printOnly = args.contains("--print")
    switch args[1] {
    case "claude": installClaudeHook(printOnly: printOnly)
    case "codex": installCodexHook(printOnly: printOnly)
    case "gemini": installGeminiHook(printOnly: printOnly)
    case "cursor": installCursorHook(printOnly: printOnly)
    case "copilot": installCopilotHook(printOnly: printOnly)
    case "aider": installAiderHook(printOnly: printOnly)
    default: fail("Unknown tool '\(args[1])'. Use claude, codex, gemini, cursor, copilot, or aider.")
    }
case "--help", "-h", "help", nil:
    printUsage()
case .some(let command):
    fail("Unknown command '\(command)'. Run `lockpaw --help`.")
}
