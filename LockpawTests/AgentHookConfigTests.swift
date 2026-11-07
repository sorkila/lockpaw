import XCTest
@testable import Lockpaw

final class AgentHookConfigTests: XCTestCase {

    private let command = "\"$HOME/.local/bin/lockpaw\" ping"
    private let matchers = ["Notification": "permission_prompt|agent_completed"]

    private func merged(_ root: [String: Any]) -> [String: Any] {
        AgentHookConfig.mergingPingHook(
            into: root, events: ["Notification", "Stop"], command: command, matchers: matchers
        )
    }

    private func groups(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(_ group: [String: Any]) -> [String] {
        (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    func testEmptyConfig_getsOneGroupPerEvent_matcherOnlyWhereGiven() {
        let result = merged([:])

        let notification = groups(result, "Notification")
        XCTAssertEqual(notification.count, 1)
        XCTAssertEqual(commands(notification[0]), [command])
        XCTAssertEqual(notification[0]["matcher"] as? String, "permission_prompt|agent_completed")

        let stop = groups(result, "Stop")
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(commands(stop[0]), [command])
        XCTAssertNil(stop[0]["matcher"])
    }

    func testOlderLockpawHook_isUpgradedInPlace_andGainsTheMatcher() {
        let old: [String: Any] = ["hooks": ["Notification": [
            ["hooks": [["type": "command", "command": "lockpaw ping"]]],
        ]]]
        let notification = groups(merged(old), "Notification")

        XCTAssertEqual(notification.count, 1)
        XCTAssertEqual(commands(notification[0]), [command])
        XCTAssertEqual(notification[0]["matcher"] as? String, "permission_prompt|agent_completed")
    }

    func testForeignGroups_areLeftUntouched() {
        let foreign: [String: Any] = ["matcher": "auth_success", "hooks": [["type": "command", "command": "say hi"]]]
        let notification = groups(merged(["hooks": ["Notification": [foreign]]]), "Notification")

        XCTAssertEqual(notification.count, 2)
        XCTAssertEqual(notification[0]["matcher"] as? String, "auth_success")
        XCTAssertEqual(commands(notification[0]), ["say hi"])
        XCTAssertEqual(commands(notification[1]), [command])
    }

    func testLockpawHookSharingAGroup_isUpgradedButTheGroupKeepsItsMatcher() {
        let shared: [String: Any] = ["hooks": [
            ["type": "command", "command": "say hi"],
            ["type": "command", "command": "lockpaw ping"],
        ]]
        let notification = groups(merged(["hooks": ["Notification": [shared]]]), "Notification")

        XCTAssertEqual(notification.count, 1)
        XCTAssertEqual(commands(notification[0]), ["say hi", command])
        XCTAssertNil(notification[0]["matcher"])
    }

    func testMergingTwice_changesNothing() {
        let once = merged([:])
        let twice = merged(once)
        XCTAssertEqual(once as NSDictionary, twice as NSDictionary)
    }

    func testUnrelatedSettings_survive() {
        let result = merged(["model": "opus", "hooks": ["PreToolUse": [["hooks": []]]]])
        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertEqual(groups(result, "PreToolUse").count, 1)
    }

    func testIsLockpawPingCommand() {
        XCTAssertTrue(AgentHookConfig.isLockpawPingCommand("lockpaw ping"))
        XCTAssertTrue(AgentHookConfig.isLockpawPingCommand(command))
        XCTAssertFalse(AgentHookConfig.isLockpawPingCommand("lockpaw install-cli"))
        XCTAssertFalse(AgentHookConfig.isLockpawPingCommand("say hi"))
    }

    /// Codex's hooks.json takes per-hook fields (a short timeout); they land on a fresh
    /// hook and on an upgraded one alike.
    func testHookFieldsLandOnNewAndUpgradedHooks() {
        let fresh = AgentHookConfig.mergingPingHook(
            into: [:], events: ["PermissionRequest"], command: command, hookFields: ["timeout": 5]
        )
        let hook = (groups(fresh, "PermissionRequest")[0]["hooks"] as? [[String: Any]])?[0]
        XCTAssertEqual(hook?["timeout"] as? Int, 5)
        XCTAssertEqual(hook?["command"] as? String, command)

        let old: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": "lockpaw ping"]]]]]]
        let upgraded = AgentHookConfig.mergingPingHook(
            into: old, events: ["PermissionRequest"], command: command, hookFields: ["timeout": 5]
        )
        let groupsAfter = groups(upgraded, "PermissionRequest")
        XCTAssertEqual(groupsAfter.count, 1)
        XCTAssertEqual((groupsAfter[0]["hooks"] as? [[String: Any]])?[0]["timeout"] as? Int, 5)
    }

    /// `idle_prompt` covers a turn that ended just before the screen was locked.
    func testClaudeMatcherIncludesIdlePromptButNotAuthSuccess() {
        let types = AgentHookConfig.claudeNotificationMatcher.split(separator: "|").map(String.init)
        XCTAssertTrue(types.contains("idle_prompt"))
        XCTAssertTrue(types.contains("permission_prompt"))
        XCTAssertFalse(types.contains("auth_success"))
    }

    // MARK: - Codex notify (TOML)

    private let lockpawArgv = ["/Users/me/.local/bin/lockpaw", "ping", "--agent", "codex"]
    private let notify = #"notify = ["/Users/me/.local/bin/lockpaw", "ping", "--agent", "codex"]"#

    private func merge(_ config: String) -> AgentHookConfig.CodexNotifyMerge {
        AgentHookConfig.mergingCodexNotify(into: config, command: lockpawArgv)
    }

    func testCodexNotifyLineIsTheArgvAsATomlArray() {
        XCTAssertEqual(CodexConfig.notifyLine(lockpawArgv), notify)
        XCTAssertEqual(CodexConfig.quoted(#"say "done" \ now"#), #""say \"done\" \\ now""#)
    }

    // Absent

    func testCodexNotifyGoesAboveTheFirstTable() {
        let config = "model = \"gpt-5\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        XCTAssertEqual(merge(config), .added("model = \"gpt-5\"\n\(notify)\n\n[mcp_servers.github]\ncommand = \"gh\"\n"))
    }

    func testCodexNotifyAppendsWhenThereAreNoTables() {
        XCTAssertEqual(merge("model = \"x\""), .added("model = \"x\"\n\(notify)\n"))
        XCTAssertEqual(merge(""), .added("\(notify)\n"))
    }

    func testCodexNotifyIntoAFileThatStartsWithATable() {
        guard case .added(let result) = merge("[profiles.work]\nmodel = \"o3\"\n") else {
            return XCTFail("expected added")
        }
        XCTAssertTrue(result.hasPrefix("\(notify)\n\n[profiles.work]"))
    }

    /// A comment right above a header describes the table, so the new line goes above it.
    func testCodexNotifyKeepsAHeadersCommentWithItsHeader() {
        let config = "# Codex\nmodel = \"o3\" # fast\n# MCP servers\n[mcp_servers.x]\ncommand = \"x\"\n"
        XCTAssertEqual(merge(config), .added("# Codex\nmodel = \"o3\" # fast\n\(notify)\n\n# MCP servers\n[mcp_servers.x]\ncommand = \"x\"\n"))
    }

    /// A `notify` key inside a table isn't the top-level one Codex reads.
    func testNotifyInsideATableDoesNotCount() {
        let config = "[profiles.work]\nnotify = [\"other\"]\n"
        guard case .added(let result) = merge(config) else { return XCTFail("expected added") }
        XCTAssertTrue(result.hasPrefix(notify))
        XCTAssertTrue(result.hasSuffix("[profiles.work]\nnotify = [\"other\"]\n"))
    }

    /// `[` inside a value (an array, a string) is not a table header.
    func testBracketsInsideValuesAreNotHeaders() {
        let config = "sandbox = [\n  \"a\",\n  \"[b]\",\n]\nmodel = \"[x]\"\n[tui]\n"
        XCTAssertEqual(merge(config), .added("sandbox = [\n  \"a\",\n  \"[b]\",\n]\nmodel = \"[x]\"\n\(notify)\n\n[tui]\n"))
    }

    func testAnEmptyNotifyIsReplaced() {
        XCTAssertEqual(merge("notify = []\n[tui]\n"), .added("\(notify)\n[tui]\n"))
    }

    // Already Lockpaw

    func testCodexOldLockpawNotifyIsUpgradedInPlace() {
        let config = "notify = [\"/x/lockpaw\", \"ping\"]\n[tui]\nnotifications = true\n"
        XCTAssertEqual(merge(config), .upgraded("\(notify)\n[tui]\nnotifications = true\n"))
        XCTAssertEqual(merge("\(notify)\n"), .unchanged)
    }

    /// Same argv written another way (multi-line, literal strings) is already right.
    func testCodexLockpawNotifyInAnotherLayoutIsUnchanged() {
        let config = "notify = [\n  '/Users/me/.local/bin/lockpaw', # Lockpaw\n  \"ping\", \"--agent\", \"codex\",\n]\n"
        XCTAssertEqual(merge(config), .unchanged)
    }

    /// Upgrading Lockpaw's own entry keeps whatever it already chains to.
    func testCodexUpgradeKeepsTheChain() {
        let config = "notify = [\"/x/lockpaw\", \"ping\", \"--\", \"terminal-notifier\", \"-title\", \"Codex\"]\n"
        let chained = CodexConfig.notifyLine(lockpawArgv + ["--", "terminal-notifier", "-title", "Codex"])
        XCTAssertEqual(merge(config), .upgraded("\(chained)\n"))
        XCTAssertEqual(merge("\(chained)\n"), .unchanged)
    }

    // Another tool's notify

    /// #45: another tool's notify used to be left alone, so Codex never called Lockpaw.
    /// Now it runs after Lockpaw's ping, unchanged.
    func testCodexForeignNotifyIsChainedAfterLockpaw() {
        let config = "model = \"o3\"\nnotify = [\"python3\", \"/Users/me/notify.py\"]\n\n[tui]\n"
        let expected = CodexConfig.notifyLine(lockpawArgv + ["--", "python3", "/Users/me/notify.py"])
        XCTAssertEqual(merge(config), .chained("model = \"o3\"\n\(expected)\n\n[tui]\n", original: ["python3", "/Users/me/notify.py"]))
        // Running it again finds Lockpaw's line and changes nothing.
        guard case .chained(let once, _) = merge(config) else { return XCTFail("expected chained") }
        XCTAssertEqual(merge(once), .unchanged)
    }

    func testCodexForeignNotifyWithEscapesSurvivesTheRoundTrip() {
        let config = #"notify = ['C:\odd path\n.sh', "say \"done\"", "tab\there"]"# + "\n"
        let original = [#"C:\odd path\n.sh"#, "say \"done\"", "tab\there"]
        guard case .chained(let text, let parsed) = merge(config) else { return XCTFail("expected chained") }
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(CodexConfig.scan(text)?.notify?.argv, lockpawArgv + ["--"] + original)
    }

    func testCodexNotifyThatIsNotAnArrayOfStringsIsNeverRewritten() {
        XCTAssertEqual(merge("notify = \"terminal-notifier\"\n"), .unreadable)
        XCTAssertEqual(merge("notify = [\"a\", 1]\n"), .unreadable)
    }

    func testCodexConfigThatDoesNotScanIsNeverRewritten() {
        XCTAssertEqual(merge("model = \"unterminated\n[tui]\n"), .unreadable)
        XCTAssertEqual(merge("notify = [\"a\"\n"), .unreadable)
        XCTAssertEqual(merge("notify = [\"a\"]\nnotify = [\"b\"]\n"), .unreadable)
    }

    // Tables and comments

    /// Only the notify statement changes. Comments, tables, multi-line strings and
    /// inline tables around it come through byte for byte.
    func testCodexChainPreservesEverythingElse() {
        let before = """
        # Codex settings
        model = "gpt-5" # default
        instructions = \"\"\"
        [not a table]
        notify = ["fake"]
        \"\"\"
        env = { PATH = "/bin", list = [1, 2] }
        """
        let after = """

        # The notifier
        [mcp_servers.github] # tools
        command = "gh"
        notify = ["table-scoped"]

        [profiles.work]
        model = "o3"

        """
        let config = before + "\nnotify = [\n  \"/usr/local/bin/notifier\", # mine\n  \"--quiet\",\n] # keep this\n" + after
        let expected = before + "\n" + CodexConfig.notifyLine(lockpawArgv + ["--", "/usr/local/bin/notifier", "--quiet"]) + " # keep this\n" + after
        XCTAssertEqual(merge(config), .chained(expected, original: ["/usr/local/bin/notifier", "--quiet"]))
    }

    func testCodexScanFindsTheFirstTableAndOnlyTheTopLevelNotify() {
        let config = "a = 1\n# [comment]\nnotify = [\"x\"]\n  [tui]\nnotify = [\"y\"]\n"
        let scan = CodexConfig.scan(config)
        XCTAssertEqual(scan?.notify?.argv, ["x"])
        XCTAssertEqual(scan?.firstTable, config.distance(from: config.startIndex, to: config.range(of: "  [tui]")!.lowerBound))
    }

    func testCodexScanReadsQuotedKeysAndCRLF() {
        XCTAssertEqual(CodexConfig.scan("\"notify\" = [\"x\"]\r\n[tui]\r\n")?.notify?.argv, ["x"])
        XCTAssertNil(CodexConfig.scan("notify.inner = [\"x\"]\n")?.notify)
    }

    // The chain at ping time

    func testSplitChainKeepsTheirCommandAndPassesThePayloadToBoth() {
        let payload = #"{"type":"agent-turn-complete","thread-id":"t1"}"#
        let split = CodexConfig.splitChain(["ping", "--agent", "codex", "--", "notify.sh", "--done", payload])
        XCTAssertEqual(split.own, ["ping", "--agent", "codex", payload])
        XCTAssertEqual(split.chained, ["notify.sh", "--done", payload])
        // Their flags never reach Lockpaw's parser: --done after the separator is theirs.
        let theirs = CodexConfig.splitChain(["ping", "--agent", "codex", "--", "notify.sh", "--error"])
        XCTAssertNil(AgentPing.userInfo(arguments: theirs.own, stdinPayload: [:])[AgentPing.Key.kind])
        XCTAssertEqual(AgentPing.userInfo(arguments: split.own, stdinPayload: [:])[AgentPing.Key.sessionID], "t1")
    }

    func testSplitChainWithoutASeparatorIsAPlainPing() {
        let split = CodexConfig.splitChain(["ping", "--agent", "codex", "{\"type\":\"x\"}"])
        XCTAssertEqual(split.own, ["ping", "--agent", "codex", "{\"type\":\"x\"}"])
        XCTAssertEqual(split.chained, [])
    }
}
