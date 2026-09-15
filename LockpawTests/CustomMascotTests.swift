import XCTest
import AppKit
@testable import Lockpaw

@MainActor
final class CustomMascotTests: XCTestCase {
    private var directory: URL!
    private var store: CustomMascot!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CustomMascotTests-\(UUID().uuidString)", isDirectory: true)
        store = CustomMascot(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Empty state

    func testNothingInstalledInitially() {
        XCTAssertFalse(store.hasImage)
        XCTAssertNil(store.loadImage())
    }

    // MARK: - Install

    func testInstallCopiesTheImageIntoTheStore() throws {
        try store.install(from: makeImageFile(pixels: 24))

        XCTAssertTrue(store.hasImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL.path))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 24, height: 24))
    }

    func testInstallCreatesTheDirectoryWhenMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try store.install(from: makeImageFile(pixels: 8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testInstallReplacesAPreviousImage() throws {
        try store.install(from: makeImageFile(pixels: 10))
        try store.install(from: makeImageFile(pixels: 30))

        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 30, height: 30))
    }

    /// Validation happens before the write, so a junk file can never wipe a working mascot.
    func testInstallRejectsAFileThatIsNotAnImage() throws {
        let junk = directory.appendingPathComponent("junk.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("definitely not an image".utf8).write(to: junk)

        XCTAssertThrowsError(try store.install(from: junk))
        XCTAssertFalse(store.hasImage)
    }

    func testARejectedInstallLeavesTheExistingImageIntact() throws {
        try store.install(from: makeImageFile(pixels: 16))

        let junk = directory.appendingPathComponent("junk.png")
        try Data("definitely not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try store.install(from: junk))

        XCTAssertTrue(store.hasImage)
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 16, height: 16))
    }

    func testInstallThrowsWhenTheSourceDoesNotExist() {
        let missing = directory.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try store.install(from: missing))
        XCTAssertFalse(store.hasImage)
    }

    // MARK: - Downsampling (a photo must not sit decoded at full size for hours)

    func testInstallDownsamplesToTheMaximumEdge() throws {
        try store.install(from: makeImageFile(pixels: CustomMascot.maxPixelSize * 3))

        let size = try XCTUnwrap(store.loadImage()?.size)
        XCTAssertEqual(max(size.width, size.height), CGFloat(CustomMascot.maxPixelSize))
    }

    func testInstallNeverUpscalesASmallImage() throws {
        try store.install(from: makeImageFile(pixels: 24))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 24, height: 24))
    }

    // MARK: - hasImage is cached, so it must be seeded from disk

    func testHasImageIsSeededFromDiskForANewStore() throws {
        try store.install(from: makeImageFile(pixels: 8))

        let fresh = CustomMascot(directory: directory)
        XCTAssertTrue(fresh.hasImage)
        XCTAssertTrue(fresh.canShow(.custom))
    }

    // MARK: - Remove

    func testRemoveDeletesTheImage() throws {
        try store.install(from: makeImageFile(pixels: 12))
        store.remove()

        XCTAssertFalse(store.hasImage)
        XCTAssertNil(store.loadImage())
    }

    func testRemoveOnAnEmptyStoreIsHarmless() {
        store.remove()
        XCTAssertFalse(store.hasImage)
    }

    // MARK: - Revision (what makes SwiftUI re-read the file)

    func testRevisionAdvancesOnInstallAndRemove() throws {
        let start = store.revision

        try store.install(from: makeImageFile(pixels: 8))
        let afterInstall = store.revision
        XCTAssertGreaterThan(afterInstall, start)

        store.remove()
        XCTAssertGreaterThan(store.revision, afterInstall)
    }

    func testRevisionDoesNotAdvanceOnARejectedInstall() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = directory.appendingPathComponent("junk.png")
        try Data("nope".utf8).write(to: junk)

        let start = store.revision
        XCTAssertThrowsError(try store.install(from: junk))
        XCTAssertEqual(store.revision, start)
    }

    /// The cache must not outlive the file it came from, or Settings would keep
    /// showing the old mascot after a replace.
    func testLoadImageReflectsAReplacementAfterCaching() throws {
        try store.install(from: makeImageFile(pixels: 10))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 10, height: 10))

        try store.install(from: makeImageFile(pixels: 40))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 40, height: 40))
    }

    // MARK: - What the views gate on

    /// The "render nothing, never fall back to Dog" rule.
    func testCanShowFollowsTheInstalledImage() throws {
        XCTAssertTrue(store.canShow(.dog))
        XCTAssertTrue(store.canShow(.cat))
        XCTAssertFalse(store.canShow(.hidden))
        XCTAssertFalse(store.canShow(.custom))

        try store.install(from: makeImageFile(pixels: 8))
        XCTAssertTrue(store.canShow(.custom))

        store.remove()
        XCTAssertFalse(store.canShow(.custom))
    }

    // MARK: - Helpers

    private func makeImageFile(pixels: Int) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let data = try XCTUnwrap(rep?.representation(using: .png, properties: [:]))

        let sources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CustomMascotSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appendingPathComponent("source.png")
        try data.write(to: url)
        return url
    }
}
