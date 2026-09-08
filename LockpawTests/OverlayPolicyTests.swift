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
}
