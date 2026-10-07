import XCTest
@testable import Lockpaw

final class OverlayPolicyTests: XCTestCase {

    /// The security-relevant invariant. A window that ignores mouse events is
    /// transparent to the pointer, so clicks reach the app underneath it — the cover
    /// would be visual only. This must hold for ambient screens too: that is exactly
    /// where it regressed (clicks on a secondary display reached the app beneath).
    func testNoOverlayIsEverTransparentToThePointer() {
        for isPrimary in [true, false] {
            XCTAssertFalse(
                OverlayPolicy.config(isPrimary: isPrimary).ignoresMouseEvents,
                "overlay on \(isPrimary ? "primary" : "ambient") screen must swallow clicks"
            )
        }
    }

    /// Only the primary carries the fallback-auth controls, so only it takes key status.
    func testOnlyPrimaryTakesKeyStatus() {
        XCTAssertTrue(OverlayPolicy.config(isPrimary: true).acceptsKey)
        XCTAssertFalse(OverlayPolicy.config(isPrimary: false).acceptsKey)
    }

    func testConfigIsFullyDeterminedByScreenRole() {
        XCTAssertEqual(
            OverlayPolicy.config(isPrimary: true),
            OverlayWindowConfig(ignoresMouseEvents: false, acceptsKey: true)
        )
        XCTAssertEqual(
            OverlayPolicy.config(isPrimary: false),
            OverlayWindowConfig(ignoresMouseEvents: false, acceptsKey: false)
        )
    }

    /// Mirror mode: for one auth attempt the clicked screen takes key so the system dialog
    /// opens where the user is looking; nothing else does.
    func testFocusedScreenTakesKeyForOneAttempt() {
        XCTAssertTrue(OverlayPolicy.acceptsKey(index: 1, focusedIndex: 1))
        XCTAssertFalse(OverlayPolicy.acceptsKey(index: 0, focusedIndex: 1))
        XCTAssertFalse(OverlayPolicy.acceptsKey(index: 2, focusedIndex: 1))
    }

    /// With no attempt in flight, routing falls back to the primary-only rule.
    func testUnfocusedRoutingMatchesPrimaryOnlyRule() {
        for index in 0..<3 {
            XCTAssertEqual(
                OverlayPolicy.acceptsKey(index: index, focusedIndex: nil),
                OverlayPolicy.config(isPrimary: index == 0).acceptsKey
            )
        }
    }
}
