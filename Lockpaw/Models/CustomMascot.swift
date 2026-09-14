import AppKit

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

    let directory: URL

    @Published private(set) var revision = 0

    private var cached: NSImage?

    init(directory: URL) {
        self.directory = directory
    }

    /// Extension is nominal — every image format is sniffed from the bytes, not the name.
    var imageURL: URL { directory.appendingPathComponent("CustomMascot.png") }

    var hasImage: Bool { FileManager.default.fileExists(atPath: imageURL.path) }

    /// Whether `mascot` will draw anything. Call sites gate their surrounding glows
    /// and shadows on this so an absent mascot leaves no orphaned lighting.
    func canShow(_ mascot: Mascot) -> Bool {
        mascot.assetName != nil || (mascot == .custom && hasImage)
    }

    func loadImage() -> NSImage? {
        if let cached { return cached }
        guard let image = NSImage(contentsOf: imageURL), image.isValid else { return nil }
        cached = image
        return image
    }

    /// Decode-validates before writing, so a junk file can never wipe a working mascot.
    /// The write is atomic for the same reason.
    func install(from source: URL) throws {
        let data = try Data(contentsOf: source)
        guard let image = NSImage(data: data), image.isValid else { throw CocoaError(.fileReadCorruptFile) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: imageURL, options: .atomic)

        cached = image
        revision += 1
    }

    func remove() {
        try? FileManager.default.removeItem(at: imageURL)
        cached = nil
        revision += 1
    }
}
