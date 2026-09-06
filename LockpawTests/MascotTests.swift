import XCTest
@testable import Lockpaw

final class MascotTests: XCTestCase {
    func testDefaultMascotIsDog() {
        XCTAssertEqual(Mascot.defaultValue, Mascot.dog.rawValue)
    }

    func testMascotAssetNames() {
        XCTAssertEqual(Mascot.dog.assetName, "Mascot")
        XCTAssertEqual(Mascot.cat.assetName, "MascotCat")
    }

    func testResolvedMascotFallsBackToDog() {
        XCTAssertEqual(Mascot.resolved(from: "cat"), .cat)
        XCTAssertEqual(Mascot.resolved(from: "unknown"), .dog)
    }

    func testHiddenMascotHasNoAsset() {
        XCTAssertEqual(Mascot.resolved(from: "none"), .hidden)
        XCTAssertNil(Mascot.hidden.assetName)
        XCTAssertEqual(Mascot.hidden.displayName, "None")
    }

    func testHiddenIsLastOption() {
        // Settings lists the cases in declaration order; "None" belongs after the two mascots.
        XCTAssertEqual(Mascot.allCases.last, .hidden)
    }
}
