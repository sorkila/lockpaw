import CoreGraphics
import Foundation
import ImageIO

/// ImageIO's thumbnail path: decodes straight to the requested size instead of
/// decoding the full image and scaling it, so a 6K HEIC never sits in memory at
/// full size. Shared by the custom mascot store and the wallpaper background.
enum ImageDownsampling {
    /// `source`'s first image, no larger than `maxPixelSize` on its longest edge. Smaller
    /// images come back at their own size (never upscaled) and EXIF orientation is baked in.
    static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image at `url` downsampled to cover `targetPixels` (scaled to fill, as the
    /// lock screen draws it). Blocking — call it off the main thread.
    static func image(at url: URL, filling targetPixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let size = fillPixelSize(image: CGSize(width: width, height: height), target: targetPixels)
        return thumbnail(from: source, maxPixelSize: size)
    }

    /// The longest edge the image needs so that, scaled to fill `target`, it lands at one
    /// image pixel per screen pixel — capped at the image's own size. An image wider than
    /// the screen's aspect needs a longer edge than the screen's own, or it would soften.
    /// With no known size (unreadable properties) the screen's long edge is the guess.
    static func fillPixelSize(image: CGSize, target: CGSize) -> Int {
        let targetLong = max(target.width, target.height)
        guard image.width > 0, image.height > 0, target.width > 0, target.height > 0 else {
            return Int(targetLong.rounded(.up))
        }
        let fill = max(target.width / image.width, target.height / image.height)
        let needed = max(image.width, image.height) * min(fill, 1)
        return Int(needed.rounded(.up))
    }
}
