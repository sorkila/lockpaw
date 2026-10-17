import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decoded frames of an animated custom mascot.
struct MascotAnimation {
    let frames: [CGImage]
    let delays: [TimeInterval]
    let duration: TimeInterval

    static let defaultFrameDelay: TimeInterval = 0.1

    init(frames: [CGImage], delays: [TimeInterval]) {
        self.frames = frames
        self.delays = delays
        self.duration = delays.reduce(0, +)
    }

    var shortestDelay: TimeInterval { delays.min() ?? Self.defaultFrameDelay }

    /// The loop is anchored to the reference date, so the lock screen and the Settings
    /// preview agree on the frame and a re-render never restarts the animation.
    func frame(at date: Date) -> CGImage {
        var elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
        for (index, delay) in delays.enumerated() {
            if elapsed < delay { return frames[index] }
            elapsed -= delay
        }
        return frames[frames.count - 1]
    }
}

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

    /// Every frame of an animated mascot stays decoded for the whole lock session, so
    /// the frame edge shrinks as the frame count grows to keep the total under this.
    static let animationMemoryBudget = 80 * 1024 * 1024
    static let maxAnimationFrames = 240
    static let minAnimationPixelSize = 256

    private static let fileName = "CustomMascot.png"

    let directory: URL

    @Published private(set) var revision = 0

    /// Cached rather than stat'd on demand: view bodies read it, and the lock screen
    /// re-evaluates its body on every breath frame.
    @Published private(set) var hasImage: Bool

    private var cached: NSImage?
    private var cachedAnimation: MascotAnimation?
    private var animationResolved = false

    init(directory: URL) {
        self.directory = directory
        self.hasImage = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.fileName).path
        )
    }

    /// Always a real PNG: `install` re-encodes whatever the user picked. An animated
    /// source becomes an APNG, which still reads as its first frame anywhere else.
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

    /// Nil for a still image. Frames are decoded once, up front: decoding at display
    /// rate would burn CPU for the hours the lock screen stays up.
    func loadAnimation() -> MascotAnimation? {
        if animationResolved { return cachedAnimation }
        animationResolved = true
        guard hasImage,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              Self.isAnimated(source) else { return nil }

        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, options) else { continue }
            frames.append(frame)
            delays.append(Self.frameDelay(in: source, at: index) ?? MascotAnimation.defaultFrameDelay)
        }
        guard frames.count > 1 else { return nil }
        cachedAnimation = MascotAnimation(frames: frames, delays: delays)
        return cachedAnimation
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

        clearCaches()
        hasImage = true
        revision += 1
    }

    func remove() {
        try? FileManager.default.removeItem(at: imageURL)
        clearCaches()
        hasImage = false
        revision += 1
    }

    private func clearCaches() {
        cached = nil
        cachedAnimation = nil
        animationResolved = false
    }

    /// Re-encodes `data` as a PNG no larger than `maxPixelSize` on its longest edge.
    /// Smaller images pass through at their own size (never upscaled); EXIF orientation
    /// is baked in so a phone photo lands the right way up. Returns nil for anything
    /// ImageIO cannot decode.
    static func downsampledPNG(from data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if isAnimated(source) {
            return downsampledAPNG(from: source, maxPixelSize: maxPixelSize)
        }
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

    /// Frames past `maxAnimationFrames` are dropped rather than rejecting the file.
    private static func downsampledAPNG(from source: CGImageSource, maxPixelSize: Int) -> Data? {
        let frameCount = min(CGImageSourceGetCount(source), maxAnimationFrames)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: animationPixelSize(frameCount: frameCount, maxPixelSize: maxPixelSize),
            kCGImageSourceShouldCache: false,
        ]

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, frameCount, nil) else {
            return nil
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0],
        ] as CFDictionary)

        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            let delay = frameDelay(in: source, at: index) ?? MascotAnimation.defaultFrameDelay
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Longest frame edge that keeps every decoded RGBA frame inside `animationMemoryBudget`.
    static func animationPixelSize(frameCount: Int, maxPixelSize: Int) -> Int {
        let fit = Int((Double(animationMemoryBudget) / Double(4 * max(frameCount, 1))).squareRoot())
        return min(maxPixelSize, max(minAnimationPixelSize, fit))
    }

    /// Multi-image files without frame timing (a multi-page TIFF, a HEIC burst) stay stills.
    static func isAnimated(_ source: CGImageSource) -> Bool {
        CGImageSourceGetCount(source) > 1 && frameDelay(in: source, at: 0) != nil
    }

    /// Delays of 10 ms or less play at 100 ms, the convention browsers follow for GIFs
    /// authored with a zero delay.
    static func frameDelay(in source: CGImageSource, at index: Int) -> TimeInterval? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return nil
        }
        let containers: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for container in containers {
            guard let values = properties[container.dictionary] as? [CFString: Any],
                  let delay = (values[container.unclamped] as? Double) ?? (values[container.clamped] as? Double) else { continue }
            return delay > 0.01 ? delay : MascotAnimation.defaultFrameDelay
        }
        return nil
    }
}
