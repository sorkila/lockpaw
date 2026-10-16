import AVFoundation
import SwiftUI

/// The desktop wallpaper behind the lock UI — an Aerial clip (playing or frozen, see
/// `WallpaperPlaybackPolicy`) or a still, dimmed so the mascot, message and timer stay
/// legible.
struct WallpaperBackgroundView: View {
    let content: WallpaperContent

    /// The scrim: an even dim, plus extra shade behind the centred content and under the
    /// unlock prompt, so the edges keep more of the wallpaper than the text does. Chosen
    /// by rendering the lock screen over frames of real Aerials and a near-white sky:
    /// these put the dimmest text (the timer, white at 0.35) at about 3.1:1 over the
    /// Aerials — what it gets on today's black lock screen (3.0:1) — and 2.5:1 over the
    /// sky, where the old flat 35% gave 1.5:1. The `.plusLighter` ping glow still doubles
    /// the centre's luminance at its peak on every background tried.
    static let dim = 0.50
    static let centreShade = 0.35
    static let promptShade = 0.35

    var body: some View {
        ZStack {
            switch content {
            case .clip(let clip):
                ClipLayerView(clip: clip)
            case .still(let still):
                StillWallpaperView(still: still)
            }

            scrim
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var scrim: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(Self.dim)
                RadialGradient(
                    colors: [.black.opacity(Self.centreShade), .clear],
                    center: .center, startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.55
                )
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.6), .init(color: .black.opacity(Self.promptShade), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }
}

/// Draws the already-decoded still; nothing until the decode lands, then fades it in
/// over the overlay's black backdrop (explicit opacity — see OverlayRootView).
private struct StillWallpaperView: View {
    @ObservedObject var still: WallpaperStill

    var body: some View {
        Color.clear
            .overlay {
                if let image = still.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .opacity(still.image == nil ? 0 : 1)
            .animation(Constants.Anim.entrance, value: still.image == nil)
    }
}

/// This screen's layer on the shared clip player. The player itself belongs to
/// `WallpaperClip`; the layer only tells it when it is in a window, so a fade to black
/// (which unmounts the lock UI) leaves no layer and the player pauses.
private struct ClipLayerView: NSViewRepresentable {
    let clip: WallpaperClip

    func makeNSView(context: Context) -> PlayerLayerView {
        PlayerLayerView(clip: clip)
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: ()) {
        nsView.detach()
    }

    final class PlayerLayerView: NSView {
        private let clip: WallpaperClip
        private let playerLayer: AVPlayerLayer
        private var counted = false
        private var readyObservation: NSKeyValueObservation?

        init(clip: WallpaperClip) {
            self.clip = clip
            playerLayer = AVPlayerLayer(player: clip.player)
            super.init(frame: .zero)
            playerLayer.videoGravity = .resizeAspectFill
            // Fade the first frame in rather than popping from black once it decodes.
            playerLayer.opacity = 0
            layer = playerLayer
            wantsLayer = true
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.8)
                    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
                    layer.opacity = 1
                    CATransaction.commit()
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !counted {
                counted = true
                clip.layerAppeared()
            } else if window == nil {
                detach()
            }
        }

        func detach() {
            guard counted else { return }
            counted = false
            clip.layerDisappeared()
        }
    }
}
