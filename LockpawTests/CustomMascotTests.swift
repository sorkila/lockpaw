import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
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

    // MARK: - Animation

    func testAStillImageHasNoAnimation() throws {
        try store.install(from: makeImageFile(pixels: 16))
        XCTAssertNil(store.loadAnimation())
    }

    func testInstallKeepsEveryFrameAndItsDelay() throws {
        try store.install(from: makeAnimatedGIF(pixels: 16, delays: [0.05, 0.1, 0.2]))

        let animation = try XCTUnwrap(store.loadAnimation())
        XCTAssertEqual(animation.frames.count, 3)
        XCTAssertEqual(animation.delays[0], 0.05, accuracy: 0.001)
        XCTAssertEqual(animation.delays[1], 0.1, accuracy: 0.001)
        XCTAssertEqual(animation.delays[2], 0.2, accuracy: 0.001)
        XCTAssertEqual(animation.duration, 0.35, accuracy: 0.001)
    }

    /// Anything reading the stored file as a plain PNG still gets a usable first frame.
    func testAnAnimatedInstallStillLoadsAsAnImage() throws {
        try store.install(from: makeAnimatedGIF(pixels: 20, delays: [0.1, 0.1]))
        XCTAssertEqual(store.loadImage()?.size, NSSize(width: 20, height: 20))
    }

    func testZeroDelayFramesPlayAtTheBrowserDefault() throws {
        try store.install(from: makeAnimatedGIF(pixels: 8, delays: [0, 0]))
        let animation = try XCTUnwrap(store.loadAnimation())
        XCTAssertEqual(animation.delays.count, 2)
        for delay in animation.delays {
            XCTAssertEqual(delay, MascotAnimation.defaultFrameDelay, accuracy: 0.001)
        }
    }

    func testReplacingAnAnimationWithAStillDropsTheCachedAnimation() throws {
        try store.install(from: makeAnimatedGIF(pixels: 8, delays: [0.1, 0.1]))
        XCTAssertNotNil(store.loadAnimation())

        try store.install(from: makeImageFile(pixels: 8))
        XCTAssertNil(store.loadAnimation())
    }

    func testRemoveDropsTheCachedAnimation() throws {
        try store.install(from: makeAnimatedGIF(pixels: 8, delays: [0.1, 0.1]))
        XCTAssertNotNil(store.loadAnimation())

        store.remove()
        XCTAssertNil(store.loadAnimation())
    }

    /// A multi-page TIFF has several images but no timing — it is not an animation.
    func testAMultiImageFileWithoutTimingStaysStill() throws {
        let url = try makeMultiImageFile(type: .tiff, pixels: 8, count: 2, frameProperties: nil)
        try store.install(from: url)

        XCTAssertTrue(store.hasImage)
        XCTAssertNil(store.loadAnimation())
    }

    func testAnimationFramesShrinkToStayInsideTheMemoryBudget() {
        XCTAssertEqual(CustomMascot.animationPixelSize(frameCount: 2, maxPixelSize: 1024), 1024)

        let edge = CustomMascot.animationPixelSize(frameCount: 120, maxPixelSize: 1024)
        XCTAssertLessThanOrEqual(120 * edge * edge * 4, CustomMascot.animationMemoryBudget)
        XCTAssertGreaterThanOrEqual(edge, CustomMascot.minAnimationPixelSize)
    }

    func testAnimationFramesNeverDropBelowTheMinimumEdge() {
        let edge = CustomMascot.animationPixelSize(frameCount: CustomMascot.maxAnimationFrames * 10, maxPixelSize: 1024)
        XCTAssertEqual(edge, CustomMascot.minAnimationPixelSize)
    }

    func testFrameAtDateWalksTheDelaysAndLoops() throws {
        let frames = try (0..<3).map { _ in try makeCGImage(pixels: 1) }
        let animation = MascotAnimation(frames: frames, delays: [0.1, 0.2, 0.3])

        func frame(at seconds: TimeInterval) -> CGImage {
            animation.frame(at: Date(timeIntervalSinceReferenceDate: seconds))
        }
        XCTAssertTrue(frame(at: 0.05) === frames[0])
        XCTAssertTrue(frame(at: 0.15) === frames[1])
        XCTAssertTrue(frame(at: 0.45) === frames[2])
        XCTAssertTrue(frame(at: 0.65) === frames[0])
    }

    // MARK: - Helpers

    private func makeAnimatedGIF(pixels: Int, delays: [TimeInterval]) throws -> URL {
        let frames = delays.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] as CFDictionary }
        let url = try makeMultiImageFile(type: .gif, pixels: pixels, count: delays.count, frameProperties: frames)
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), delays.count, "fixture must really be animated")
        return url
    }

    private func makeMultiImageFile(type: UTType, pixels: Int, count: Int, frameProperties: [CFDictionary]?) throws -> URL {
        let url = try makeSourcesDirectory().appendingPathComponent("source.\(type.preferredFilenameExtension ?? "img")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        if type == .gif {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
        }
        for index in 0..<count {
            CGImageDestinationAddImage(destination, try makeCGImage(pixels: pixels), frameProperties?[index])
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeCGImage(pixels: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0.83, blue: 0.67, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeSourcesDirectory() throws -> URL {
        let sources = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CustomMascotSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        return sources
    }

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
