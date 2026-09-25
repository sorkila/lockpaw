import AVFoundation
import SwiftUI

/// The desktop wallpaper behind the lock UI — a muted, looping Aerial clip or a still,
/// dimmed so the mascot, message and timer stay legible. Draws nothing when no
/// wallpaper resolves, leaving the overlay's black backdrop.
struct WallpaperBackgroundView: View {
    let source: DesktopWallpaper.Source?

    var body: some View {
        ZStack {
            switch source {
            case .video(let url):
                LoopingVideoView(url: url)
            case .image(let url):
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            case nil:
                EmptyView()
            }

            if source != nil {
                Color.black.opacity(0.35)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// ponytail: one decoder per screen; share a single player across displays if multi-4K playback shows up in energy use.
private struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(url: url)
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {}

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private let looper: AVPlayerLooper

        init(url: URL) {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            super.init(frame: .zero)
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            wantsLayer = true
            player.isMuted = true
            // Keep the display awake decisions with SleepPreventer, not the player.
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { player.pause() } else { player.play() }
        }
    }
}
