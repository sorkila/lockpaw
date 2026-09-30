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
}
