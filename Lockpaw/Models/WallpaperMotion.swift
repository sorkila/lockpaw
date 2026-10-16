import Foundation

/// When an Aerial wallpaper moves behind the lock screen (Settings → Lock Screen, shown
/// while "Desktop wallpaper" is on).
///
/// `SleepPreventer` keeps the display awake for the whole lock, so with fade to black
/// off a playing Aerial is a 4K HEVC decode running for hours. One player is shared by
/// every screen showing the same clip, and this decides whether it runs at all. A
/// paused clip holds its current frame, so "not playing" still shows the Aerial.
enum WallpaperMotion: String, CaseIterable, Identifiable {
    case always
    case pluggedIn
    case never

    static let storageKey = "wallpaperMotion"
    /// Laptops on battery get a still Aerial unless the user asks otherwise.
    static let defaultValue = pluggedIn.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: return "Always"
        case .pluggedIn: return "Plugged in"
        case .never: return "Never"
        }
    }

    static func resolved(from rawValue: String?) -> WallpaperMotion {
        rawValue.flatMap(WallpaperMotion.init(rawValue:)) ?? .pluggedIn
    }

    /// Read once at lock() time, like the fade delay.
    static var current: WallpaperMotion {
        resolved(from: UserDefaults.standard.string(forKey: storageKey))
    }
}

/// Whether a shared Aerial player runs right now. Pure, so every branch is tested.
enum WallpaperPlaybackPolicy {
    struct Conditions: Equatable {
        var motion: WallpaperMotion
        var reduceMotion: Bool
        var onBattery: Bool
        var lowPowerMode: Bool
        /// Player layers currently in a window. Zero while faded to black (the lock UI
        /// is unmounted) or once the overlay is gone.
        var visibleLayers: Int
    }

    static func shouldPlay(_ conditions: Conditions) -> Bool {
        guard conditions.visibleLayers > 0, !conditions.reduceMotion else { return false }
        switch conditions.motion {
        case .always:
            return true
        case .pluggedIn:
            // Low Power Mode is the user asking the whole Mac to save energy.
            return !conditions.onBattery && !conditions.lowPowerMode
        case .never:
            return false
        }
    }
}
