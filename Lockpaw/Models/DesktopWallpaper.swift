import AppKit

/// The user's macOS desktop wallpaper as a lock-screen background.
///
/// `NSWorkspace.desktopImageURL(for:)` only ever returns a still, so an animated
/// Aerial would show as a frozen frame. For Aerials the wallpaper agent keeps the
/// selected clip on disk as `aerials/videos/<assetID>.mov`, and its choice lives in
/// `Store/Index.plist` — neither is public API, so every step falls back: a missing
/// or unparseable store, a shape this code doesn't know, or a clip that has not
/// downloaded yet all land on the still.
///
/// The store is layered (shape read from macOS 26/27):
///
///     AllSpacesAndDisplays             every display, every Space
///     Displays/<display UUID>          one display, every Space
///     Spaces/<space UUID>/Default      one Space, any display
///     Spaces/<space UUID>/Displays/<display UUID>
///
/// Each entry holds `Desktop` (or `Linked`, when the screen saver shares the choice);
/// an entry of `Type` `idle` carries only the screen saver. A screen resolves to its
/// most specific entry that has a desktop choice, display before Space, so a display
/// with its own photo never shows a global Aerial. Stale entries linger (switching
/// "Show on all Spaces" leaves the old per-Space ones behind), so an entry naming a
/// single image file that is not what NSWorkspace says is on screen is skipped.
enum DesktopWallpaper {
    static let enabledKey = "showDesktopWallpaper"
    static let defaultEnabled = false

    enum Source: Equatable {
        case video(URL)
        case image(URL)
    }

    /// Which store entries can apply to a screen: its display's UUID
    /// (`CGDisplayCreateUUIDFromDisplayID`) and the Space it is showing.
    struct Placement: Equatable {
        var display: String?
        var space: String?
    }

    /// One layer's desktop choice, as far as the background cares.
    enum Choice: Equatable {
        case aerial(assetID: String)
        case imageFile(URL)
        /// Anything else — a colour, a folder or shuffle, a dynamic or shader wallpaper,
        /// an Aerial with no usable ID, or a shape we don't recognise. The still covers it.
        case other
    }

    static let aerialsProvider = "com.apple.wallpaper.choice.aerials"

    static let wallpaperDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper", isDirectory: true)

    static var indexURL: URL { wallpaperDirectory.appendingPathComponent("Store/Index.plist") }
    static var aerialsDirectory: URL { wallpaperDirectory.appendingPathComponent("aerials", isDirectory: true) }

    /// The wallpaper for `screen` right now. `indexPlist` and `managedSpaces` are read
    /// once per lock by the caller and shared by every screen. Whether an Aerial moves
    /// (Reduce Motion, battery, the setting) is `WallpaperPlaybackPolicy`'s call — a
    /// paused clip still shows the Aerial itself, where NSWorkspace's still may not.
    static func current(for screen: NSScreen, indexPlist: Data?, managedSpaces: [[String: Any]]?) -> Source? {
        let still = NSWorkspace.shared.desktopImageURL(for: screen)
        let display = DisplaySpaces.uuid(for: screen)
        return source(
            indexPlist: indexPlist,
            aerialsDirectory: aerialsDirectory,
            placement: Placement(display: display, space: DisplaySpaces.currentSpace(forDisplay: display, in: managedSpaces)),
            stillImage: still,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    /// Pure resolution: this screen's Aerial clip if one is selected and on disk, else the still.
    static func source(
        indexPlist: Data?,
        aerialsDirectory: URL,
        placement: Placement,
        stillImage: URL?,
        fileExists: (URL) -> Bool
    ) -> Source? {
        if let assetID = aerialAssetID(fromIndexPlist: indexPlist, placement: placement, stillImage: stillImage) {
            let video = aerialsDirectory.appendingPathComponent("videos/\(assetID).mov")
            if fileExists(video) { return .video(video) }
        }
        return stillImage.map(Source.image)
    }

    /// The Aerial this screen shows, or nil when its wallpaper is anything else.
    static func aerialAssetID(fromIndexPlist data: Data?, placement: Placement, stillImage: URL?) -> String? {
        guard let data, let root = plist(data) else { return nil }
        for entry in layers(root, placement: placement) {
            // nil: this layer sets no desktop (screen-saver-only, or empty) — look wider.
            guard let choice = desktopChoice(of: entry) else { continue }
            switch choice {
            case .aerial(let assetID):
                return assetID
            case .imageFile(let url):
                // A single photo that isn't on screen is a leftover — look wider.
                if let stillImage, !samePath(url, stillImage) { continue }
                return nil
            case .other:
                return nil
            }
        }
        return nil
    }

    /// The entries that can apply to `placement`, most specific first.
    static func layers(_ root: [String: Any], placement: Placement) -> [[String: Any]] {
        let space = placement.space.flatMap { (root["Spaces"] as? [String: Any])?[$0] as? [String: Any] }
        var layers: [[String: Any]] = []
        if let display = placement.display {
            if let entry = (space?["Displays"] as? [String: Any])?[display] as? [String: Any] { layers.append(entry) }
            if let entry = (root["Displays"] as? [String: Any])?[display] as? [String: Any] { layers.append(entry) }
        }
        if let entry = space?["Default"] as? [String: Any] { layers.append(entry) }
        if let entry = root["AllSpacesAndDisplays"] as? [String: Any] { layers.append(entry) }
        return layers
    }

    /// The desktop choice an entry makes, or nil when it makes none.
    static func desktopChoice(of entry: [String: Any]) -> Choice? {
        let side = entry["Type"] as? String == "linked"
            ? entry["Linked"]
            : entry["Desktop"] ?? entry["Linked"]
        guard let side else { return nil }
        // Something is set here, so from now on any surprise ends on the still.
        guard let content = (side as? [String: Any])?["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [Any])?.first as? [String: Any],
              let provider = choice["Provider"] as? String
        else { return .other }
        let configuration = (choice["Configuration"] as? Data).flatMap(plist)

        if provider == aerialsProvider {
            guard let assetID = configuration?["assetID"] as? String, isSafeAssetID(assetID) else { return .other }
            return .aerial(assetID: assetID)
        }
        if configuration?["type"] as? String == "imageFile", let url = fileURL(configuration?["url"]) {
            return .imageFile(url)
        }
        return .other
    }

    /// The ID becomes a path component — refuse anything that could walk out of it.
    static func isSafeAssetID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..") && !id.contains("\0")
    }

    /// `{relative: "file:///…"}` on macOS 26/27; a bare string is accepted too.
    private static func fileURL(_ value: Any?) -> URL? {
        let string = (value as? [String: Any])?["relative"] as? String ?? value as? String
        guard let string, let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
