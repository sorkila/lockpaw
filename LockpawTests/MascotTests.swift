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
        // Settings lists the free cases in order; "None" belongs last.
        XCTAssertEqual(Mascot.freeCases.last, .hidden)
    }

    func testCustomMascotHasNoBundledAsset() {
        XCTAssertEqual(Mascot.resolved(from: "custom"), .custom)
        XCTAssertNil(Mascot.custom.assetName)
        XCTAssertEqual(Mascot.custom.displayName, "Custom")
    }

    func testCustomSitsBetweenTheBuiltInsAndNone() {
        XCTAssertEqual(Mascot.freeCases, [.dog, .cat, .custom, .hidden])
    }

    // MARK: - Supporter mascots

    private let allAssets: (String) -> Bool = { _ in true }
    private let noAssets: (String) -> Bool = { _ in false }

    func testSupporterMascotsAreTheFourAndNotFree() {
        XCTAssertEqual(Mascot.supporterCases, [.fox, .owl, .redPanda, .bunny])
        for mascot in Mascot.supporterCases {
            XCTAssertTrue(mascot.isSupporterOnly)
            XCTAssertFalse(Mascot.freeCases.contains(mascot))
            XCTAssertNotNil(mascot.assetName)
        }
        for mascot in Mascot.freeCases { XCTAssertFalse(mascot.isSupporterOnly) }
    }

    func testSupporterMascotNeedsASupporter() {
        XCTAssertEqual(Mascot.resolved(from: "fox", isSupporter: true, assetExists: allAssets), .fox)
        XCTAssertEqual(Mascot.resolved(from: "fox", isSupporter: false, assetExists: allAssets), .dog)
    }

    func testSupporterMascotNeedsItsArt() {
        XCTAssertEqual(Mascot.resolved(from: "redpanda", isSupporter: true, assetExists: noAssets), .dog)
    }

    func testFreeMascotsIgnoreSupporterState() {
        for mascot in Mascot.freeCases {
            XCTAssertEqual(Mascot.resolved(from: mascot.rawValue, isSupporter: false, assetExists: noAssets), mascot)
        }
    }

    // MARK: - Seasonal skins

    func testSeasonalVariantForSupportersOnly() {
        XCTAssertEqual(Mascot.dog.displayAssetName(season: .halloween, seasonalEnabled: true, isSupporter: true, assetExists: allAssets), "Mascot-halloween")
        XCTAssertEqual(Mascot.cat.displayAssetName(season: .winter, seasonalEnabled: true, isSupporter: true, assetExists: allAssets), "MascotCat-winter")
        XCTAssertEqual(Mascot.dog.displayAssetName(season: .halloween, seasonalEnabled: true, isSupporter: false, assetExists: allAssets), "Mascot")
        XCTAssertEqual(Mascot.dog.displayAssetName(season: .halloween, seasonalEnabled: false, isSupporter: true, assetExists: allAssets), "Mascot")
    }

    func testSeasonalFallsBackToBaseWithoutArtOrSeason() {
        XCTAssertEqual(Mascot.dog.displayAssetName(season: .midsummer, seasonalEnabled: true, isSupporter: true, assetExists: noAssets), "Mascot")
        XCTAssertEqual(Mascot.dog.displayAssetName(season: nil, seasonalEnabled: true, isSupporter: true, assetExists: allAssets), "Mascot")
    }

    func testOnlyDogAndCatGetSeasons() {
        XCTAssertEqual(Mascot.fox.displayAssetName(season: .halloween, seasonalEnabled: true, isSupporter: true, assetExists: allAssets), "MascotFox")
        XCTAssertNil(Mascot.hidden.displayAssetName(season: .halloween, seasonalEnabled: true, isSupporter: true, assetExists: allAssets))
    }
}

/// The art ships with the app: every supporter mascot and every seasonal Dog/Cat skin
/// resolves from the asset catalog. Code tolerates missing art (falls back to Dog or the
/// plain mascot), so without this a dropped imageset would fail silently.
final class MascotArtTests: XCTestCase {
    @MainActor func testSupporterMascotArtIsBundled() {
        for mascot in Mascot.supporterCases {
            XCTAssertTrue(Mascot.bundledAssetExists(mascot.assetName!), mascot.rawValue)
        }
    }

    @MainActor func testSeasonalSkinsAreBundledForDogAndCat() {
        for mascot in [Mascot.dog, .cat] {
            for season in SeasonalSkin.allCases {
                let name = season.assetName(base: mascot.assetName!)
                XCTAssertTrue(Mascot.bundledAssetExists(name), name)
            }
        }
    }
}
