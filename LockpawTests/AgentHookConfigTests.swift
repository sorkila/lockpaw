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

    private let notify = #"notify = ["/Users/me/.local/bin/lockpaw", "ping", "--agent", "codex"]"#

    func testCodexNotifyGoesAboveTheFirstTable() {
        let config = "model = \"gpt-5\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        guard case .added(let result) = AgentHookConfig.mergingCodexNotify(into: config, line: notify) else {
            return XCTFail("expected added")
        }
        XCTAssertEqual(result, "model = \"gpt-5\"\n\(notify)\n\n[mcp_servers.github]\ncommand = \"gh\"\n")
    }

    func testCodexNotifyAppendsWhenThereAreNoTables() {
        XCTAssertEqual(AgentHookConfig.mergingCodexNotify(into: "model = \"x\"", line: notify), .added("model = \"x\"\n\(notify)\n"))
        XCTAssertEqual(AgentHookConfig.mergingCodexNotify(into: "", line: notify), .added("\(notify)\n"))
    }

    func testCodexNotifyIntoAFileThatStartsWithATable() {
        guard case .added(let result) = AgentHookConfig.mergingCodexNotify(into: "[profiles.work]\nmodel = \"o3\"\n", line: notify) else {
            return XCTFail("expected added")
        }
        XCTAssertTrue(result.hasPrefix("\(notify)\n\n[profiles.work]"))
    }

    func testCodexOldLockpawNotifyIsUpgradedInPlace() {
        let config = "notify = [\"/x/lockpaw\", \"ping\"]\n[tui]\nnotifications = true\n"
        XCTAssertEqual(AgentHookConfig.mergingCodexNotify(into: config, line: notify),
                       .upgraded("\(notify)\n[tui]\nnotifications = true\n"))
        XCTAssertEqual(AgentHookConfig.mergingCodexNotify(into: "\(notify)\n", line: notify), .unchanged)
    }

    func testCodexForeignNotifyIsLeftAlone() {
        XCTAssertEqual(AgentHookConfig.mergingCodexNotify(into: "notify = [\"terminal-notifier\"]\n", line: notify), .foreign)
    }

    /// A `notify` key inside a table isn't the top-level one Codex reads.
    func testNotifyInsideATableDoesNotCount() {
        let config = "[profiles.work]\nnotify = [\"other\"]\n"
        guard case .added(let result) = AgentHookConfig.mergingCodexNotify(into: config, line: notify) else {
            return XCTFail("expected added")
        }
        XCTAssertTrue(result.hasPrefix(notify))
    }
}
