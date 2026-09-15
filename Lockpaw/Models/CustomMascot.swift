import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The user's own lock-screen image, copied into Application Support so it keeps
/// working after the original is moved or deleted.
///
/// `revision` is what makes SwiftUI re-read the file: the image lives on disk, not
/// in any observed value, so without it the Settings preview would keep showing the
/// previous mascot after a replace.
@MainActor
final class CustomMascot: ObservableObject {
    static let shared = CustomMascot(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
    )

    /// Longest edge the stored image is downsampled to at install. The mascot renders
    /// at a few hundred points, so anything larger is wasted memory on a screen that
    /// stays up for hours — a full-size photo would otherwise sit decoded at ~200 MB.
    static let maxPixelSize = 1024

    private static let fileName = "CustomMascot.png"

    let directory: URL

    @Published private(set) var revision = 0

    /// Cached rather than stat'd on demand: view bodies read it, and the lock screen
    /// re-evaluates its body on every breath frame.
    @Published private(set) var hasImage: Bool

    private var cached: NSImage?

    init(directory: URL) {
        self.directory = directory
        self.hasImage = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.fileName).path
        )
    }

    /// Always a real PNG: `install` re-encodes whatever the user picked.
    var imageURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Whether `mascot` will draw anything. Call sites gate their surrounding glows
    /// and shadows on this so an absent mascot leaves no orphaned lighting.
    func canShow(_ mascot: Mascot) -> Bool {
        mascot.assetName != nil || (mascot == .custom && hasImage)
    }

    func loadImage() -> NSImage? {
        if let cached { return cached }
        guard hasImage, let image = NSImage(contentsOf: imageURL), image.isValid else { return nil }
        cached = image
        return image
    }

    /// Decodes and downsamples before writing, so a junk file can never wipe a working
    /// mascot and an oversized one never reaches disk. The write is atomic for the same reason.
    func install(from source: URL) throws {
        let data = try Data(contentsOf: source)
        guard let png = Self.downsampledPNG(from: data, maxPixelSize: Self.maxPixelSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: imageURL, options: .atomic)

        cached = nil
        hasImage = true
        revision += 1
    }

    func remove() {
        try? FileManager.default.removeItem(at: imageURL)
        cached = nil
        hasImage = false
        revision += 1
    }

    /// Re-encodes `data` as a PNG no larger than `maxPixelSize` on its longest edge.
    /// Smaller images pass through at their own size (never upscaled); EXIF orientation
    /// is baked in so a phone photo lands the right way up. Returns nil for anything
    /// ImageIO cannot decode.
    static func downsampledPNG(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
