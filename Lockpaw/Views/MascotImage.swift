import SwiftUI

/// The mascot image for a preference — from the asset catalog, or from the user's
/// own file via `CustomMascot`. Call sites keep their own frame, shadow and glow
/// modifiers; this only settles where the pixels come from.
///
/// Renders nothing for `.hidden`, and nothing for `.custom` with no image installed:
/// a missing file reads as "no mascot" rather than silently falling back to Dog.
@MainActor
struct MascotImage: View {
    let mascot: Mascot

    init(_ mascot: Mascot) {
        self.mascot = mascot
    }

    var body: some View {
        image?
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private var image: Image? {
        if let assetName = mascot.assetName { return Image(assetName) }
        if mascot == .custom, let custom = CustomMascot.shared.loadImage() { return Image(nsImage: custom) }
        return nil
    }
}
