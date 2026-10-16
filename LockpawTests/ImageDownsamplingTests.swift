import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Lockpaw

/// The wallpaper still is decoded once, off main, at the size it is drawn (review point 3).
final class ImageDownsamplingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func png(width: Int, height: Int) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent("\(width)x\(height).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testSameAspectLandsOnTheScreensLongEdge() {
        XCTAssertEqual(ImageDownsampling.fillPixelSize(image: CGSize(width: 6016, height: 3384), target: CGSize(width: 5120, height: 2880)), 5120)
    }

    func testWiderImageKeepsOnePixelPerScreenPixelAcrossTheHeight() {
        // 21:9 on 16:10: filling the height needs a long edge past the screen's width.
        XCTAssertEqual(ImageDownsampling.fillPixelSize(image: CGSize(width: 6000, height: 2571), target: CGSize(width: 2880, height: 1800)), 4201)
    }

    func testNeverUpscales() {
        XCTAssertEqual(ImageDownsampling.fillPixelSize(image: CGSize(width: 1920, height: 1080), target: CGSize(width: 5120, height: 2880)), 1920)
    }

    func testUnknownImageSizeGuessesTheScreensLongEdge() {
        XCTAssertEqual(ImageDownsampling.fillPixelSize(image: .zero, target: CGSize(width: 3024, height: 1964)), 3024)
    }

    func testDecodesAtTheFillSize() throws {
        let image = ImageDownsampling.image(at: try png(width: 4000, height: 2000), filling: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(image?.width, 2000)
        XCTAssertEqual(image?.height, 1000)
    }

    func testUnreadableFilesGiveNothing() throws {
        XCTAssertNil(ImageDownsampling.image(at: directory.appendingPathComponent("missing.heic"), filling: CGSize(width: 100, height: 100)))
        let junk = directory.appendingPathComponent("junk.heic")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertNil(ImageDownsampling.image(at: junk, filling: CGSize(width: 100, height: 100)))
    }
}
