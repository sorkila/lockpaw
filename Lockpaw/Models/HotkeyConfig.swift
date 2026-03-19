import AppKit
import Carbon

struct HotkeyConfig {
    private static let keyCodeKey = "hotkeyKeyCode"
    private static let modifiersKey = "hotkeyModifiers"
    private static let displayKey = "hotkeyDisplay"
    private static let enabledKey = "hotkeyEnabled"

    static let defaultKeyCode = 37
    static let defaultModifiers = cmdKey | shiftKey
    static let defaultDisplay = "Cmd+Shift+L"
    static let defaultEnabled = true

    static var keyCode: Int {
        UserDefaults.standard.object(forKey: keyCodeKey) as? Int ?? defaultKeyCode
    }

    static var modifiers: Int {
        UserDefaults.standard.object(forKey: modifiersKey) as? Int ?? defaultModifiers
    }

    static var display: String {
        UserDefaults.standard.string(forKey: displayKey) ?? defaultDisplay
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func saveKeyCode(_ value: Int) {
        UserDefaults.standard.set(value, forKey: keyCodeKey)
    }

    static func saveModifiers(_ value: Int) {
        UserDefaults.standard.set(value, forKey: modifiersKey)
    }

    static func saveDisplay(_ value: String) {
        UserDefaults.standard.set(value, forKey: displayKey)
    }

    static func saveEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    // MARK: - System Shortcut Conflict Detection

    /// Returns a description of the conflicting system shortcut, or nil if no conflict.
    static func systemConflict(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String? {
        let cmd = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let opt = modifiers.contains(.option)
        let ctrl = modifiers.contains(.control)

        // Cmd-only shortcuts
        if cmd && !shift && !opt && !ctrl {
            switch keyCode {
            case 12: return "Cmd+Q (Quit)"           // Q
            case 13: return "Cmd+W (Close Window)"    // W
            case 0: return "Cmd+A (Select All)"       // A
            case 8: return "Cmd+C (Copy)"             // C
            case 9: return "Cmd+V (Paste)"            // V
            case 7: return "Cmd+X (Cut)"              // X
            case 6: return "Cmd+Z (Undo)"             // Z
            case 3: return "Cmd+F (Find)"             // F
            case 4: return "Cmd+H (Hide)"             // H
            case 46: return "Cmd+M (Minimize)"        // M
            case 35: return "Cmd+P (Print)"           // P
            case 1: return "Cmd+S (Save)"             // S
            case 17: return "Cmd+T (New Tab)"         // T
            case 32: return "Cmd+U (Underline)"       // U
            case 45: return "Cmd+N (New)"             // N
            case 31: return "Cmd+O (Open)"            // O
            case 48: return "Cmd+Tab (App Switcher)"  // Tab
            case 49: return "Cmd+Space (Spotlight)"   // Space
            case 44: return "Cmd+, (Settings)"        // ,
            default: break
            }
        }

        // Cmd+Shift shortcuts
        if cmd && shift && !opt && !ctrl {
            switch keyCode {
            case 6: return "Cmd+Shift+Z (Redo)"
            case 30: return "Cmd+Shift+] (Next Tab)"
            case 33: return "Cmd+Shift+[ (Previous Tab)"
            default: break
            }
        }

        // Ctrl+Cmd shortcuts
        if cmd && ctrl && !shift && !opt {
            switch keyCode {
            case 12: return "Ctrl+Cmd+Q (Lock Screen)"
            case 36: return "Ctrl+Cmd+F (Fullscreen)"  // Return key
            default: break
            }
        }

        return nil
    }
}
