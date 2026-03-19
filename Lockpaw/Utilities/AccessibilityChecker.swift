import Cocoa

struct AccessibilityChecker {
    /// Returns true if Accessibility permission is granted.
    static var isEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission if not already granted.
    static func promptIfNeeded() {
        guard !isEnabled else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings to the Accessibility pane directly.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
