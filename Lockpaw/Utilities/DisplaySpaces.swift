import AppKit

/// Which Space each display is showing, for the desktop-wallpaper background.
///
/// macOS has no public API for this. `CGSCopyManagedDisplaySpaces` is the private
/// window-server call Spaces utilities have used for years; it is looked up at runtime
/// and read only, so a macOS without it just loses the per-Space layer of the wallpaper
/// lookup (the display and all-displays layers still apply).
enum DisplaySpaces {
    /// The store's key for a display.
    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// One dictionary per display (or one `Main` entry when displays share Spaces),
    /// each with its `Current Space`. Nil when the call is unavailable.
    static func managedDisplaySpaces() -> [[String: Any]]? {
        typealias MainConnection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        let mainConnection = unsafeBitCast(connection, to: MainConnection.self)
        let copySpaces = unsafeBitCast(copy, to: CopySpaces.self)
        return copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
    }

    /// The UUID of the Space `display` is showing. With "Displays have separate Spaces"
    /// off there is a single `Main` entry for every display. The first desktop's UUID
    /// can be the empty string, and the store keys it that way too.
    static func currentSpace(forDisplay display: String?, in managed: [[String: Any]]?) -> String? {
        guard let managed else { return nil }
        let entry = managed.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(display ?? "") == .orderedSame }
            ?? managed.first { $0["Display Identifier"] as? String == "Main" }
            ?? (managed.count == 1 ? managed.first : nil)
        return (entry?["Current Space"] as? [String: Any])?["uuid"] as? String
    }
}
