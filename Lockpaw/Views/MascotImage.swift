import SwiftUI

/// The mascot image for a preference — from the asset catalog, or from the user's
/// own file via `CustomMascot`. Call sites keep their own frame, shadow and glow
/// modifiers; this only settles where the pixels come from.
///
/// Renders nothing for `.hidden`, and nothing for `.custom` with no image installed:
/// a missing file reads as "no mascot" rather than silently falling back to Dog.
///
/// A custom image gets a feathered elliptical mask. Dog and Cat are cut-outs on a
/// transparent ground, so they float in the pool of light; a photo is an opaque
/// rectangle, and without the mask it reads as a card sitting on top of the ping glow.
@MainActor
struct MascotImage: View {
    let mascot: Mascot

    init(_ mascot: Mascot) {
        self.mascot = mascot
    }

    var body: some View {
        if let image {
            let base = image
                .resizable()
                .interpolation(.high)
                .scaledToFit()

            if mascot == .custom {
                base.mask { featheredEdge }
            } else {
                base
            }
        }
    }

    private var image: Image? {
        if let assetName = mascot.displayAssetName(
            season: SeasonalSkin.current(on: Date()),
            seasonalEnabled: UserDefaults.standard.object(forKey: SeasonalSkin.enabledKey) as? Bool ?? true,
            isSupporter: Supporter.shared.isSupporter,
            assetExists: Mascot.bundledAssetExists
        ) { return Image(assetName) }
        if mascot == .custom, let custom = CustomMascot.shared.loadImage() { return Image(nsImage: custom) }
        return nil
    }

    /// Fully opaque through the middle, fading to nothing at the edge of the frame.
    private var featheredEdge: some View {
        EllipticalGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.55),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
    }
}

extension Mascot {
    /// Asset-catalog lookup, cached: the lock screen re-evaluates its body every breath frame.
    @MainActor static func bundledAssetExists(_ name: String) -> Bool {
        if let known = assetCache[name] { return known }
        let exists = NSImage(named: name) != nil
        assetCache[name] = exists
        return exists
    }

    @MainActor private static var assetCache: [String: Bool] = [:]

    /// The mascot that actually shows for a stored preference — see `resolved(from:isSupporter:assetExists:)`.
    @MainActor static func effective(from rawValue: String) -> Mascot {
        resolved(from: rawValue, isSupporter: Supporter.shared.isSupporter, assetExists: bundledAssetExists)
    }
}
