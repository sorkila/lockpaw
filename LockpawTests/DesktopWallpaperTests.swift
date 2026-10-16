import XCTest
@testable import Lockpaw

/// Fixtures follow the shape of `com.apple.wallpaper/Store/Index.plist` as read on
/// macOS 27.0 (26A434) — the same layering macOS 26 writes — with made-up UUIDs and paths.
final class DesktopWallpaperTests: XCTestCase {
    private let aerials = URL(fileURLWithPath: "/tmp/aerials", isDirectory: true)
    private let still = URL(fileURLWithPath: "/Library/Desktop Pictures/Still.heic")
    private let otherPhoto = URL(fileURLWithPath: "/Library/Desktop Pictures/Other.heic")
    private let assetID = "BD000000-0000-4000-8000-000000000010"
    private let otherAssetID = "BD000000-0000-4000-8000-000000000020"
    private let display = "D1000000-0000-4000-8000-000000000001"
    private let otherDisplay = "D2000000-0000-4000-8000-000000000002"
    private let space = "51000000-0000-4000-8000-000000000001"
    private let otherSpace = "52000000-0000-4000-8000-000000000002"
    private var here: DesktopWallpaper.Placement { .init(display: display, space: space) }

    // MARK: - Fixture builders

    private func data(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    private func aerial(_ id: String? = nil) -> [String: Any] {
        ["Provider": DesktopWallpaper.aerialsProvider, "Files": [Any](), "Configuration": data(["assetID": id ?? assetID])]
    }

    private func photo(_ url: URL) -> [String: Any] {
        ["Provider": "com.apple.wallpaper.choice.image", "Files": [Any](),
         "Configuration": data(["type": "imageFile", "url": ["relative": url.absoluteString]])]
    }

    private var color: [String: Any] {
        ["Provider": "com.apple.wallpaper.choice.color", "Files": [Any](),
         "Configuration": data(["type": "systemColor", "systemColor": ["black": [String: Any]()]])]
    }

    private func side(_ choice: [String: Any]) -> [String: Any] {
        ["LastSet": Date(timeIntervalSince1970: 1_790_000_000), "LastUse": Date(timeIntervalSince1970: 1_790_000_000),
         "Content": ["Choices": [choice], "Shuffle": "$null", "EncodedOptionValues": "$null"]]
    }

    private var idleSide: [String: Any] {
        side(["Provider": "default", "Files": [Any](), "Configuration": Data()])
    }

    /// An `individual` entry: its own desktop plus the screen saver.
    private func entry(_ choice: [String: Any]) -> [String: Any] {
        ["Type": "individual", "Desktop": side(choice), "Idle": idleSide]
    }

    /// What macOS writes for an Aerial that is also the screen saver.
    private func linked(_ choice: [String: Any]) -> [String: Any] {
        ["Type": "linked", "Linked": side(choice)]
    }

    /// Screen saver only — macOS 27's `AllSpacesAndDisplays` when every desktop is per-Space.
    private var idleOnly: [String: Any] { ["Type": "idle", "Idle": idleSide] }

    private func store(
        all: [String: Any]? = nil,
        displays: [String: Any]? = nil,
        spaces: [String: Any]? = nil
    ) -> Data {
        var root: [String: Any] = ["SystemDefault": entry(photo(otherPhoto))]
        if let all { root["AllSpacesAndDisplays"] = all }
        if let displays { root["Displays"] = displays }
        if let spaces { root["Spaces"] = spaces }
        return data(root)
    }

    private func spaceEntry(default def: [String: Any]? = nil, displays: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["Displays": displays]
        if let def { result["Default"] = def }
        return result
    }

    private func resolve(
        _ index: Data?, placement: DesktopWallpaper.Placement? = nil, still: URL? = nil,
        onDisk: Set<String>? = nil
    ) -> DesktopWallpaper.Source? {
        let onDisk = onDisk ?? ["\(assetID).mov", "\(otherAssetID).mov"]
        return DesktopWallpaper.source(
            indexPlist: index, aerialsDirectory: aerials, placement: placement ?? here,
            stillImage: still ?? self.still, fileExists: { onDisk.contains($0.lastPathComponent) }
        )
    }

    private func clip(_ id: String) -> DesktopWallpaper.Source {
        .video(aerials.appendingPathComponent("videos/\(id).mov"))
    }

    // MARK: - The global choice

    func testGlobalAerialPlays() {
        XCTAssertEqual(resolve(store(all: linked(aerial()))), clip(assetID))
        XCTAssertEqual(resolve(store(all: entry(aerial()))), clip(assetID), "Desktop as well as Linked")
    }

    func testGlobalAerialAppliesWithNoPlacement() {
        XCTAssertEqual(resolve(store(all: linked(aerial())), placement: .init()), clip(assetID))
    }

    func testAerialNotDownloadedFallsBackToTheStill() {
        XCTAssertEqual(resolve(store(all: linked(aerial())), onDisk: []), .image(still))
    }

    func testNonAerialWallpaperUsesTheStill() {
        XCTAssertEqual(resolve(store(all: entry(photo(still)))), .image(still))
        XCTAssertEqual(resolve(store(all: entry(color))), .image(still))
    }

    // MARK: - Per display and per Space (review point 1)

    func testDisplaysOwnPhotoBeatsAGlobalAerial() {
        let index = store(all: linked(aerial()), displays: [display: entry(photo(still))])
        XCTAssertEqual(resolve(index), .image(still))
    }

    func testDisplaysOwnAerialBeatsAGlobalPhoto() {
        let index = store(all: entry(photo(otherPhoto)), displays: [display: entry(aerial())])
        XCTAssertEqual(resolve(index), clip(assetID))
    }

    func testAnotherDisplaysEntryDoesNotApply() {
        let index = store(all: linked(aerial()), displays: [otherDisplay: entry(photo(still))])
        XCTAssertEqual(resolve(index), clip(assetID))
    }

    func testEachDisplayResolvesItsOwnAerial() {
        let index = store(displays: [display: entry(aerial()), otherDisplay: entry(aerial(otherAssetID))])
        XCTAssertEqual(resolve(index, placement: .init(display: display)), clip(assetID))
        XCTAssertEqual(resolve(index, placement: .init(display: otherDisplay)), clip(otherAssetID))
    }

    func testCurrentSpaceOnThisDisplayComesFirst() {
        let index = store(
            all: linked(aerial(otherAssetID)),
            displays: [display: entry(aerial(otherAssetID))],
            spaces: [space: spaceEntry(default: entry(aerial(otherAssetID)), displays: [display: entry(aerial())])]
        )
        XCTAssertEqual(resolve(index), clip(assetID))
    }

    func testSpaceDefaultAppliesWhenNothingNamesTheDisplay() {
        let index = store(all: idleOnly, spaces: [space: spaceEntry(default: entry(aerial()))])
        XCTAssertEqual(resolve(index), clip(assetID))
    }

    func testDisplayEntryOutranksTheSpaceDefault() {
        let index = store(displays: [display: entry(photo(still))], spaces: [space: spaceEntry(default: entry(aerial()))])
        XCTAssertEqual(resolve(index), .image(still))
    }

    func testAnotherSpaceDoesNotApply() {
        let index = store(
            all: entry(photo(still)),
            spaces: [otherSpace: spaceEntry(default: entry(aerial()), displays: [display: entry(aerial())])]
        )
        XCTAssertEqual(resolve(index), .image(still))
    }

    func testScreenSaverOnlyLayerIsSkipped() {
        // macOS 27 with per-Space desktops: AllSpacesAndDisplays only carries the screen saver.
        XCTAssertEqual(resolve(store(all: idleOnly, displays: [display: entry(aerial())])), clip(assetID))
        XCTAssertEqual(resolve(store(all: idleOnly)), .image(still))
    }

    func testLeftoverPhotoEntryIsSkipped() {
        // A per-Space photo that isn't on screen is a leftover from before "Show on all Spaces".
        let leftover = store(all: linked(aerial()), spaces: [space: spaceEntry(displays: [display: entry(photo(otherPhoto))])])
        XCTAssertEqual(resolve(leftover), clip(assetID))
        // The same entry, when it *is* what NSWorkspace reports, wins.
        XCTAssertEqual(resolve(leftover, still: otherPhoto), .image(otherPhoto))
    }

    func testPhotoEntryIsTrustedWhenThereIsNoStillToCompare() {
        let index = store(all: linked(aerial()), displays: [display: entry(photo(otherPhoto))])
        XCTAssertNil(DesktopWallpaper.aerialAssetID(fromIndexPlist: index, placement: here, stillImage: nil))
    }

    func testColourEntryEndsTheLookup() {
        let index = store(all: linked(aerial()), displays: [display: entry(color)])
        XCTAssertEqual(resolve(index), .image(still))
    }

    func testRealStoreShape() {
        // The layering as read on macOS 27: global screen saver only, a system default,
        // stale per-display rows for displays long gone, an empty-string Space for the
        // first desktop, and the live per-Space row for this display.
        var root: [String: Any] = [
            "AllSpacesAndDisplays": idleOnly,
            "SystemDefault": entry(photo(otherPhoto)),
            "Displays": [display: entry(photo(otherPhoto)), otherDisplay: entry(color)],
            "Spaces": [
                "": spaceEntry(default: entry(photo(otherPhoto)), displays: [otherDisplay: entry(color)]),
                space: spaceEntry(default: entry(photo(still)), displays: [display: entry(photo(still))]),
            ],
        ]
        XCTAssertEqual(resolve(data(root)), .image(still))

        root["Spaces"] = [space: spaceEntry(default: linked(aerial()), displays: [display: linked(aerial())])]
        XCTAssertEqual(resolve(data(root)), clip(assetID))
        XCTAssertEqual(resolve(data(root), placement: .init(display: display, space: "")), .image(still),
                       "a Space with no rows of its own: the leftover display photo is skipped, the still shows")
    }

    // MARK: - Fails safe (review point 5)

    func testMissingOrJunkStoreUsesTheStill() {
        XCTAssertEqual(resolve(nil), .image(still))
        XCTAssertEqual(resolve(Data("junk".utf8)), .image(still))
        XCTAssertEqual(resolve(Data()), .image(still))
        XCTAssertEqual(resolve(data([String: Any]())), .image(still), "an empty store")
        XCTAssertEqual(resolve(data(["one", "two"])), .image(still), "root is not a dictionary")
    }

    func testNoStillAndNoAerialIsNil() {
        XCTAssertNil(DesktopWallpaper.source(
            indexPlist: nil, aerialsDirectory: aerials, placement: here, stillImage: nil, fileExists: { _ in true }
        ))
    }

    func testWrongTypesNeverResolveAnAerial() {
        let config = data(["assetID": assetID])
        let bad: [[String: Any]] = [
            ["AllSpacesAndDisplays": "linked"],
            ["AllSpacesAndDisplays": ["Type": "linked", "Linked": "aerial"]],
            ["AllSpacesAndDisplays": ["Type": "linked", "Linked": ["Content": "x"]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": "x"]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [Any]()]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": ["x"]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": 7, "Configuration": config]]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": DesktopWallpaper.aerialsProvider]]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": DesktopWallpaper.aerialsProvider, "Configuration": "x"]]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": DesktopWallpaper.aerialsProvider, "Configuration": Data("junk".utf8)]]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": DesktopWallpaper.aerialsProvider, "Configuration": data(["assetID": 42])]]]]]],
            ["AllSpacesAndDisplays": ["Linked": ["Content": ["Choices": [["Provider": DesktopWallpaper.aerialsProvider, "Configuration": data(["id": assetID])]]]]]],
            ["Displays": ["x", "y"], "Spaces": "x"],
            ["Displays": [display: "x"], "Spaces": [space: ["Displays": "x", "Default": 3]]],
        ]
        for (i, root) in bad.enumerated() {
            XCTAssertEqual(resolve(data(root)), .image(still), "fixture \(i)")
        }
    }

    func testMalformedSpecificEntryEndsOnTheStill() {
        // Something is set for this display but we can't read it: don't guess the global Aerial.
        let index = store(all: linked(aerial()), displays: [display: ["Type": "individual", "Desktop": ["Content": 1]]])
        XCTAssertEqual(resolve(index), .image(still))
    }

    func testOlderShapes() {
        // No Type key, no Spaces or Displays tables — the shape Sonoma-era reports describe.
        XCTAssertEqual(resolve(data(["AllSpacesAndDisplays": ["Desktop": side(aerial())]])), clip(assetID))
        XCTAssertEqual(resolve(data(["AllSpacesAndDisplays": ["Linked": side(aerial())]])), clip(assetID))
        // A bare string URL for an image choice.
        let bareURL: [String: Any] = ["Provider": "com.apple.wallpaper.choice.image",
                                      "Configuration": data(["type": "imageFile", "url": otherPhoto.absoluteString])]
        let index = data(["AllSpacesAndDisplays": linked(aerial()), "Displays": [display: entry(bareURL)]])
        XCTAssertEqual(resolve(index), clip(assetID), "a bare-string photo that isn't on screen is a leftover too")
        // Pre-Sonoma: no store at all.
        XCTAssertEqual(resolve(nil), .image(still))
    }

    func testAssetIDCannotEscapeTheAerialsDirectory() {
        for id in ["../../evil", "", "a/b", "..", "x\0y"] {
            XCTAssertEqual(resolve(store(all: linked(aerial(id))), onDisk: ["evil.mov", ".mov", "b.mov", "...mov"]),
                           .image(still), id)
        }
        XCTAssertTrue(DesktopWallpaper.isSafeAssetID(assetID))
    }

    // MARK: - Current Space

    func testCurrentSpaceForSharedSpaces() {
        let managed: [[String: Any]] = [["Display Identifier": "Main", "Current Space": ["uuid": space, "type": 0]]]
        XCTAssertEqual(DisplaySpaces.currentSpace(forDisplay: display, in: managed), space)
        XCTAssertEqual(DisplaySpaces.currentSpace(forDisplay: nil, in: managed), space)
    }

    func testCurrentSpacePerDisplay() {
        let managed: [[String: Any]] = [
            ["Display Identifier": display.lowercased(), "Current Space": ["uuid": space]],
            ["Display Identifier": otherDisplay, "Current Space": ["uuid": otherSpace]],
        ]
        XCTAssertEqual(DisplaySpaces.currentSpace(forDisplay: display, in: managed), space)
        XCTAssertEqual(DisplaySpaces.currentSpace(forDisplay: otherDisplay, in: managed), otherSpace)
        XCTAssertNil(DisplaySpaces.currentSpace(forDisplay: "unknown", in: managed))
    }

    func testCurrentSpaceFailsSafe() {
        XCTAssertNil(DisplaySpaces.currentSpace(forDisplay: display, in: nil))
        XCTAssertNil(DisplaySpaces.currentSpace(forDisplay: display, in: []))
        XCTAssertNil(DisplaySpaces.currentSpace(forDisplay: display, in: [["Display Identifier": "Main", "Current Space": "x"]]))
        XCTAssertEqual(DisplaySpaces.currentSpace(forDisplay: display, in: [["Display Identifier": "Main", "Current Space": ["uuid": ""]]]), "",
                       "the first desktop's UUID is the empty string, and the store keys it that way")
    }

    func testOffByDefault() {
        XCTAssertFalse(DesktopWallpaper.defaultEnabled)
    }
}
