import AppKit
import AVFoundation
import ImageIO
import IOKit.ps

/// What a screen's wallpaper background shows. Built once per screen at lock time;
/// the view only reads it.
enum WallpaperContent {
    case still(WallpaperStill)
    case clip(WallpaperClip)
}

/// A still wallpaper, decoded and downsampled off the main thread. The lock screen
/// re-renders every second for its clock, so the decode can't live in a view body.
/// `image` stays nil until the decode lands (or for good, if the file won't decode),
/// and the overlay's black backdrop shows meanwhile.
@MainActor
final class WallpaperStill: ObservableObject {
    @Published private(set) var image: CGImage?

    init(url: URL, filling targetPixels: CGSize) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = ImageDownsampling.image(at: url, filling: targetPixels)
            await MainActor.run { [weak self] in self?.image = image }
        }
    }
}

/// One looping, muted Aerial clip, shared by every screen that shows it — each screen
/// gets its own `AVPlayerLayer` on this one player, so two displays on the same Aerial
/// cost one decode. Layers report when they enter and leave a window; whether the
/// player runs is `WallpaperPlaybackPolicy`'s call, made by the controller.
@MainActor
final class WallpaperClip {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper
    private(set) var visibleLayers = 0
    fileprivate var onVisibilityChange: (() -> Void)?

    init(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        // SleepPreventer owns display sleep for the lock, not the player.
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func layerAppeared() {
        visibleLayers += 1
        onVisibilityChange?()
    }

    func layerDisappeared() {
        visibleLayers = max(0, visibleLayers - 1)
        onVisibilityChange?()
    }

    fileprivate func setPlaying(_ playing: Bool) {
        // A paused player keeps showing its current frame, so pausing freezes the Aerial.
        if playing {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }
}

/// The desktop wallpaper for each overlay, for one lock session.
///
/// The store and the current Spaces are read once at `begin`. Each still is decoded
/// once per session at its screen's pixel size, and each Aerial clip gets one player
/// however many screens show it. Clips run only while `WallpaperPlaybackPolicy` says
/// so — re-checked when the power source or Low Power Mode changes, and whenever a
/// screen's layer comes or goes (fade to black unmounts them all, which pauses).
/// `end` pauses every clip and drops the session's references; views still fading out
/// keep what they hold, frozen, until the overlay windows let them go.
@MainActor
final class WallpaperController {
    private struct StillKey: Hashable {
        let url: URL
        let width: Int
        let height: Int
    }

    private var active = false
    private var motion = WallpaperMotion.pluggedIn
    private var reduceMotion = false
    private var indexPlist: Data?
    private var managedSpaces: [[String: Any]]?
    private var stills: [StillKey: WallpaperStill] = [:]
    private var clips: [URL: WallpaperClip] = [:]
    private var powerSource: CFRunLoopSource?
    private var lowPowerObserver: Any?

    func begin(motion: WallpaperMotion, reduceMotion: Bool) {
        end()
        active = true
        self.motion = motion
        self.reduceMotion = reduceMotion
        indexPlist = try? Data(contentsOf: DesktopWallpaper.indexURL)
        managedSpaces = DisplaySpaces.managedDisplaySpaces()
    }

    /// The background for the overlay on `NSScreen.screens[index]` — the overlay
    /// manager's content factory runs once per screen, in that order, and again on a
    /// display change.
    func content(forScreenAt index: Int) -> WallpaperContent? {
        let screens = NSScreen.screens
        guard active, screens.indices.contains(index) else { return nil }
        let screen = screens[index]
        switch DesktopWallpaper.current(for: screen, indexPlist: indexPlist, managedSpaces: managedSpaces) {
        case .video(let url):
            return .clip(clip(url))
        case .image(let url):
            return .still(still(url, for: screen))
        case nil:
            return nil
        }
    }

    func end() {
        active = false
        indexPlist = nil
        managedSpaces = nil
        stills.removeAll()
        for clip in clips.values {
            clip.onVisibilityChange = nil
            clip.setPlaying(false)
        }
        clips.removeAll()
        stopObservingPower()
    }

    private func still(_ url: URL, for screen: NSScreen) -> WallpaperStill {
        let pixels = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        let key = StillKey(url: url, width: Int(pixels.width), height: Int(pixels.height))
        if let cached = stills[key] { return cached }
        let still = WallpaperStill(url: url, filling: pixels)
        stills[key] = still
        return still
    }

    private func clip(_ url: URL) -> WallpaperClip {
        if let shared = clips[url] { return shared }
        let clip = WallpaperClip(url: url)
        clip.onVisibilityChange = { [weak self] in self?.refreshPlayback() }
        clips[url] = clip
        startObservingPower()
        return clip
    }

    // MARK: - Playback

    private func refreshPlayback() {
        let onBattery = Self.isOnBattery
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        for clip in clips.values {
            clip.setPlaying(WallpaperPlaybackPolicy.shouldPlay(.init(
                motion: motion, reduceMotion: reduceMotion, onBattery: onBattery,
                lowPowerMode: lowPower, visibleLayers: clip.visibleLayers
            )))
        }
    }

    private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
    }

    /// Only while a clip exists — a still or no wallpaper needs no power events.
    private func startObservingPower() {
        if powerSource == nil {
            // Unretained: the source is removed in `end`, and the controller lives as long
            // as the LockController that owns it.
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let controller = Unmanaged<WallpaperController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { controller.refreshPlayback() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                powerSource = source
            }
        }
        if lowPowerObserver == nil {
            lowPowerObserver = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPlayback() }
            }
        }
    }

    private func stopObservingPower() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
        if let observer = lowPowerObserver {
            NotificationCenter.default.removeObserver(observer)
            lowPowerObserver = nil
        }
    }

    /// Opens each screen's still once, off the main thread, when the setting is switched
    /// on. A wallpaper kept in Desktop, Documents or Downloads makes macOS ask for folder
    /// access the first time Lockpaw reads it, and behind a shield-level overlay that
    /// prompt would never be seen — so it comes up here, in front of Settings, instead.
    static func requestAccessToStills() {
        let urls = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        Task.detached(priority: .utility) {
            for url in Set(urls) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                _ = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            }
        }
    }
}
