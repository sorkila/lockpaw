import Foundation

// The `lockpaw` command-line tool. Lets AI coding agents (Claude Code, Codex,
// Gemini CLI, or anything scriptable) ping Lockpaw so the locked screen glows and
// a notification fires when they need you.
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
      lockpaw install-hook <tool>   Wire up an agent. <tool>: claude | codex | gemini
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

func installCLI() {
    let fm = FileManager.default
    guard let exec = currentBinaryURL() else {
        fail("Could not determine the lockpaw binary path.")
    }

    let binDir = homeDirectory().appendingPathComponent(".local/bin", isDirectory: true)
    let link = binDir.appendingPathComponent("lockpaw")

    do {
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Refresh an existing link/file so re-running picks up a moved app.
        if (try? link.checkResourceIsReachable()) == true || fm.fileExists(atPath: link.path) {
            try? fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: exec)
        print("✓ Linked lockpaw → \(link.path)")
    } catch {
        fail("Could not create symlink: \(error.localizedDescription)")
    }

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

func writeJSON(_ object: [String: Any], to url: URL, label: String) {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
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

func installClaudeHook(printOnly: Bool) {
    let snippet = """
    Add to ~/.claude/settings.json:

      "hooks": {
        "Notification": [{ "hooks": [{ "type": "command", "command": "lockpaw ping" }] }],
        "Stop":         [{ "hooks": [{ "type": "command", "command": "lockpaw ping" }] }]
      }
    """
    if printOnly { print(snippet); return }

    let url = homeDirectory().appendingPathComponent(".claude/settings.json")
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = obj
    }

    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for event in ["Notification", "Stop"] {
        var groups = hooks[event] as? [[String: Any]] ?? []
        let present = groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == "lockpaw ping" } ?? false
        }
        if !present {
            groups.append(["hooks": [["type": "command", "command": "lockpaw ping"]]])
        }
        hooks[event] = groups
    }
    root["hooks"] = hooks
    writeJSON(root, to: url, label: "Claude Code")
}

func installCodexHook(printOnly: Bool) {
    let line = "notify = [\"lockpaw\", \"ping\"]"
    if printOnly {
        print("Add to ~/.codex/config.toml (user-level — `notify` is ignored in project configs):\n\n  \(line)")
        return
    }

    let fm = FileManager.default
    let url = homeDirectory().appendingPathComponent(".codex/config.toml")
    var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

    if contents.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) != nil {
        print("""
        ⚠️  ~/.codex/config.toml already defines `notify` — leaving it untouched.
        To route Codex through Lockpaw, set it to:
            \(line)
        """)
        return
    }

    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.copyItem(at: url, to: url.appendingPathExtension("bak"))
        }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += line + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        print("✓ Added notify hook to Codex config at \(url.path)")
    } catch {
        fail("Could not write Codex config: \(error.localizedDescription)")
    }
}

func installGeminiHook() {
    // Gemini CLI's hook schema is still stabilizing, so we print rather than write.
    print("""
    Gemini CLI hooks live in ~/.gemini/settings.json. Add a hook on a completion or
    notification event that runs:

        lockpaw ping

    See https://geminicli.com/docs/hooks/ for the current schema, then point the hook
    command at `lockpaw ping`.
    """)
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
        fail("Usage: lockpaw install-hook <claude|codex|gemini> [--print]")
    }
    let printOnly = args.contains("--print")
    switch args[1] {
    case "claude": installClaudeHook(printOnly: printOnly)
    case "codex": installCodexHook(printOnly: printOnly)
    case "gemini": installGeminiHook()
    default: fail("Unknown tool '\(args[1])'. Use claude, codex, or gemini.")
    }
case "--help", "-h", "help", nil:
    printUsage()
case .some(let command):
    fail("Unknown command '\(command)'. Run `lockpaw --help`.")
}
