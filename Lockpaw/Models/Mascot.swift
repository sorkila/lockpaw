import Foundation

enum Mascot: String, CaseIterable, Identifiable {
    case dog
    case cat
    /// Supporter thank-yous. Listed only once their art ships (`isAvailable`), and a
    /// non-supporter (say, a licence removed) falls back to Dog rather than keeping one.
    case fox
    case owl
    case redPanda = "redpanda"
    case bunny
    /// The user's own image, stored by `CustomMascot` rather than the asset catalog.
    case custom
    /// No mascot at all: the lock screen is just the message and the timer.
    /// Raw value "none" is what Settings stores; the case is named `hidden` so
    /// call sites never collide with `Optional.none`.
    case hidden = "none"

    static let storageKey = "mascot"
    static let defaultValue = dog.rawValue

    /// What everyone gets, in Settings order.
    static let freeCases: [Mascot] = [.dog, .cat, .custom, .hidden]
    static let supporterCases: [Mascot] = [.fox, .owl, .redPanda, .bunny]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .fox: return "Fox"
        case .owl: return "Owl"
        case .redPanda: return "Red panda"
        case .bunny: return "Bunny"
        case .custom: return "Custom"
        case .hidden: return "None"
        }
    }

    var isSupporterOnly: Bool { Self.supporterCases.contains(self) }

    /// Image asset for the mascot, or nil when there is no bundled asset to show.
    var assetName: String? {
        switch self {
        case .dog: return "Mascot"
        case .cat: return "MascotCat"
        case .fox: return "MascotFox"
        case .owl: return "MascotOwl"
        case .redPanda: return "MascotRedPanda"
        case .bunny: return "MascotBunny"
        case .custom, .hidden: return nil
        }
    }

    /// Seasonal skins exist for the two original mascots only.
    var hasSeasonalSkins: Bool { self == .dog || self == .cat }

    static func resolved(from rawValue: String) -> Mascot {
        Mascot(rawValue: rawValue) ?? .dog
    }

    /// What actually shows: a supporter mascot needs a supporter and its art; otherwise Dog.
    static func resolved(from rawValue: String, isSupporter: Bool, assetExists: (String) -> Bool) -> Mascot {
        let mascot = resolved(from: rawValue)
        guard mascot.isSupporterOnly else { return mascot }
        guard isSupporter, let asset = mascot.assetName, assetExists(asset) else { return .dog }
        return mascot
    }

    /// The asset to draw: this season's variant when it applies and exists, else the base.
    func displayAssetName(season: SeasonalSkin?, seasonalEnabled: Bool, isSupporter: Bool, assetExists: (String) -> Bool) -> String? {
        guard let base = assetName else { return nil }
        guard hasSeasonalSkins, isSupporter, seasonalEnabled, let season else { return base }
        let seasonal = season.assetName(base: base)
        return assetExists(seasonal) ? seasonal : base
    }
}
