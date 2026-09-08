import Foundation

/// How one overlay window is configured for the screen it covers.
struct OverlayWindowConfig: Equatable {
    /// Always false. A window that ignores mouse events is transparent to the pointer,
    /// so clicks land on whatever app sits underneath it — which for a screen guard
    /// means the cover is only visual. Every overlay swallows clicks.
    let ignoresMouseEvents: Bool
    /// Only the primary overlay takes key status, so ambient screens can't pull focus
    /// away from the screen carrying the fallback-auth controls.
    let acceptsKey: Bool
}

/// Pure per-screen overlay rules, kept out of AppKit so the security-relevant
/// invariant — no overlay is ever transparent to the pointer — is unit-tested.
enum OverlayPolicy {
    static func config(isPrimary: Bool) -> OverlayWindowConfig {
        OverlayWindowConfig(ignoresMouseEvents: false, acceptsKey: isPrimary)
    }
}
