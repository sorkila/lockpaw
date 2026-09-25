import AppKit

/// The user's macOS desktop wallpaper as a lock-screen background.
///
/// `NSWorkspace.desktopImageURL(for:)` only ever returns a still, so an animated
/// Aerial would show as a frozen frame. For Aerials the wallpaper agent keeps the
/// selected clip on disk as `aerials/videos/<assetID>.mov`, and its choice lives in
/// `Store/Index.plist` — neither is public API, so every step falls back: a missing
/// or unparseable store, or a clip that has not downloaded yet, lands on the still.
enum DesktopWallpaper {
    static let enabledKey = "showDesktopWallpaper"
    static let defaultEnabled = false

    enum Source: Equatable {
        case video(URL)
        case image(URL)
    }

    private static let aerialsProvider = "com.apple.wallpaper.choice.aerials"

    static let wallpaperDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper", isDirectory: true)

    /// The wallpaper for `screen` right now. Under Reduce Motion an Aerial resolves to
    /// its thumbnail, so nothing moves.
    static func current(for screen: NSScreen, reduceMotion: Bool) -> Source? {
        source(
            indexPlist: try? Data(contentsOf: wallpaperDirectory.appendingPathComponent("Store/Index.plist")),
            aerialsDirectory: wallpaperDirectory.appendingPathComponent("aerials", isDirectory: true),
            stillImage: NSWorkspace.shared.desktopImageURL(for: screen),
            reduceMotion: reduceMotion,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Pure resolution: the Aerial clip if one is selected and on disk, else the still.
    static func source(
        indexPlist: Data?,
        aerialsDirectory: URL,
        stillImage: URL?,
        reduceMotion: Bool,
        fileExists: (URL) -> Bool
    ) -> Source? {
        if let assetID = aerialAssetID(fromIndexPlist: indexPlist) {
            let video = aerialsDirectory.appendingPathComponent("videos/\(assetID).mov")
            let thumbnail = aerialsDirectory.appendingPathComponent("thumbnails/\(assetID).png")
            if !reduceMotion, fileExists(video) { return .video(video) }
            if fileExists(thumbnail) { return .image(thumbnail) }
        }
        return stillImage.map(Source.image)
    }

    /// The selected Aerial's asset ID, or nil when the wallpaper is not an Aerial.
    // ponytail: reads the all-displays choice only; a per-display Aerial falls back to the still.
    static func aerialAssetID(fromIndexPlist data: Data?) -> String? {
        guard let data,
              let root = plist(data),
              let all = root["AllSpacesAndDisplays"] as? [String: Any],
              let entry = (all["Linked"] ?? all["Desktop"]) as? [String: Any],
              let content = entry["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              choice["Provider"] as? String == aerialsProvider,
              let configData = choice["Configuration"] as? Data,
              let assetID = plist(configData)?["assetID"] as? String,
              // The ID becomes a path component — refuse anything that could walk out of it.
              !assetID.isEmpty, !assetID.contains("/"), !assetID.contains("..")
        else { return nil }
        return assetID
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
