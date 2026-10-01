import XCTest
@testable import Lockpaw

final class ScreenLayoutTests: XCTestCase {

    private func layout(_ screens: [(UInt32, CGRect, CGFloat)]) -> ScreenLayout {
        ScreenLayout(screens: screens.map { ScreenLayout.Screen(displayID: $0.0, frame: $0.1, scale: $0.2) })
    }

    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func testSameDisplaysCompareEqual() {
        XCTAssertEqual(layout([(1, builtIn, 2), (2, external, 1)]), layout([(1, builtIn, 2), (2, external, 1)]))
    }

    /// The equality the overlay rebuild hinges on: plugging in, moving or rescaling a
    /// display is a change; Dock or menu bar visibility is not represented at all.
    func testRealDisplayChangesCompareUnequal() {
        let base = layout([(1, builtIn, 2)])
        XCTAssertNotEqual(base, layout([(1, builtIn, 2), (2, external, 1)]), "display added")
        XCTAssertNotEqual(base, layout([(1, CGRect(x: 0, y: 0, width: 1800, height: 1169), 2)]), "resolution changed")
        XCTAssertNotEqual(base, layout([(1, builtIn, 1)]), "scale changed")
        XCTAssertNotEqual(base, layout([(3, builtIn, 2)]), "different display")
    }

    /// Order matters: index 0 is the primary overlay, so a primary swap must rebuild.
    func testPrimarySwapCompareUnequal() {
        XCTAssertNotEqual(layout([(1, builtIn, 2), (2, external, 1)]), layout([(2, external, 1), (1, builtIn, 2)]))
    }
}
