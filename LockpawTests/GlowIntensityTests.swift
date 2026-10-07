import XCTest
@testable import Lockpaw

final class GlowIntensityTests: XCTestCase {
    /// #19: today's resting glow (2.4% teal at the centre) can't be seen across a room, so
    /// the default must be brighter than it, and today's look must still be available.
    func testDefaultRestsBrighterThanThe15Look() {
        XCTAssertEqual(GlowIntensity.defaultValue, .normal)
        XCTAssertGreaterThan(GlowIntensity.normal.restLevel, GlowIntensity.subtle.restLevel)
        XCTAssertEqual(GlowIntensity.subtle.restLevel, 0.08, "Subtle keeps the 1.5 resting level")
        XCTAssertEqual(GlowIntensity.subtle.peakScale, 1.0)
    }

    func testLevelsAreOrdered() {
        let levels = GlowIntensity.allCases.map(\.restLevel)
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertGreaterThanOrEqual(GlowIntensity.bright.peakScale, GlowIntensity.normal.peakScale)
    }

    func testCentreOpacityIsCapped() {
        XCTAssertEqual(GlowIntensity.subtle.centreOpacity(at: 1), 0.30, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(GlowIntensity.bright.centreOpacity(at: 1), 0.5)
        XCTAssertEqual(GlowIntensity.normal.centreOpacity(at: 0), 0)
    }

    func testResolution() {
        XCTAssertEqual(GlowIntensity.resolved(from: "bright"), .bright)
        XCTAssertEqual(GlowIntensity.resolved(from: "nonsense"), .normal)
        XCTAssertEqual(GlowIntensity.resolved(from: nil), .normal)
    }
}
