import XCTest
@testable import Lockpaw

final class DesktopWallpaperTests: XCTestCase {
    private let aerials = URL(fileURLWithPath: "/tmp/aerials", isDirectory: true)
    private let still = URL(fileURLWithPath: "/tmp/still.heic")
    private let assetID = "BD000000-0000-4000-8000-000000000010"

    /// Same shape as macOS 26's `com.apple.wallpaper/Store/Index.plist`.
    private func index(provider: String = "com.apple.wallpaper.choice.aerials", assetID: String? = nil, key: String = "Linked") -> Data {
        let config = try! PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID ?? self.assetID], format: .binary, options: 0
        )
        let root: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Type": "linked",
                key: ["Content": ["Choices": [["Provider": provider, "Configuration": config, "Files": []]]]],
            ],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private func resolve(_ data: Data?, reduceMotion: Bool = false, onDisk: Set<String>) -> DesktopWallpaper.Source? {
        DesktopWallpaper.source(
            indexPlist: data, aerialsDirectory: aerials, stillImage: still,
            reduceMotion: reduceMotion, fileExists: { onDisk.contains($0.lastPathComponent) }
        )
    }

    func testReadsTheSelectedAerial() {
        XCTAssertEqual(DesktopWallpaper.aerialAssetID(fromIndexPlist: index()), assetID)
        XCTAssertEqual(DesktopWallpaper.aerialAssetID(fromIndexPlist: index(key: "Desktop")), assetID)
    }

    func testDownloadedAerialPlaysItsClip() {
        let source = resolve(index(), onDisk: ["\(assetID).mov", "\(assetID).png"])
        XCTAssertEqual(source, .video(aerials.appendingPathComponent("videos/\(assetID).mov")))
    }

    func testReduceMotionShowsTheThumbnail() {
        let source = resolve(index(), reduceMotion: true, onDisk: ["\(assetID).mov", "\(assetID).png"])
        XCTAssertEqual(source, .image(aerials.appendingPathComponent("thumbnails/\(assetID).png")))
    }

    func testAerialNotDownloadedFallsBackToTheStill() {
        XCTAssertEqual(resolve(index(), onDisk: []), .image(still))
    }

    func testNonAerialWallpaperUsesTheStill() {
        XCTAssertNil(DesktopWallpaper.aerialAssetID(fromIndexPlist: index(provider: "com.apple.wallpaper.choice.image")))
        XCTAssertEqual(resolve(index(provider: "com.apple.wallpaper.choice.image"), onDisk: ["\(assetID).mov"]), .image(still))
    }

    func testMissingOrJunkStoreUsesTheStill() {
        XCTAssertEqual(resolve(nil, onDisk: []), .image(still))
        XCTAssertEqual(resolve(Data("junk".utf8), onDisk: []), .image(still))
    }

    func testAssetIDCannotEscapeTheAerialsDirectory() {
        XCTAssertNil(DesktopWallpaper.aerialAssetID(fromIndexPlist: index(assetID: "../../evil")))
        XCTAssertNil(DesktopWallpaper.aerialAssetID(fromIndexPlist: index(assetID: "")))
    }

    func testOffByDefault() {
        XCTAssertFalse(DesktopWallpaper.defaultEnabled)
    }
}
