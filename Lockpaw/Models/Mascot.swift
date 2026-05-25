import Foundation

enum Mascot: String, CaseIterable, Identifiable {
    case dog
    case cat

    static let storageKey = "mascot"
    static let defaultValue = dog.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dog: return "Dog"
        case .cat: return "Cat"
        }
    }

    var assetName: String {
        switch self {
        case .dog: return "Mascot"
        case .cat: return "MascotCat"
        }
    }

    static func resolved(from rawValue: String) -> Mascot {
        Mascot(rawValue: rawValue) ?? .dog
    }
}
