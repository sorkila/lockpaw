import Foundation

enum Mascot: String, CaseIterable, Identifiable {
    case dog
    case cat
    /// The user's own image, stored by `CustomMascot` rather than the asset catalog.
    case custom
    /// No mascot at all: the lock screen is just the message and the timer.
    /// Raw value "none" is what Settings stores; the case is named `hidden` so
    /// call sites never collide with `Optional.none`.
    case hidden = "none"

    static let storageKey = "mascot"
    static let defaultValue = dog.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .custom: return "Custom"
        case .hidden: return "None"
        }
    }

    /// Image asset for the mascot, or nil when there is no bundled asset to show.
    var assetName: String? {
        switch self {
        case .dog: return "Mascot"
        case .cat: return "MascotCat"
        case .custom, .hidden: return nil
        }
    }

    static func resolved(from rawValue: String) -> Mascot {
        Mascot(rawValue: rawValue) ?? .dog
    }
}
