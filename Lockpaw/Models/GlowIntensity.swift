import CoreGraphics
import Foundation

/// How strongly the lock screen glows when an agent pings (#19). The promise is "you can see
/// it from across the room", and at the old resting level (2.4% teal at the centre) you
/// couldn't — so Normal is brighter than before, and today's look lives on as Subtle.
///
/// Two numbers per level, applied to the existing glow:
/// - `restLevel`: the glow held after the breaths until unlock (was `Timing.pingGlowRest`).
/// - `peakScale`: multiplies the gradient's stops at the top of each breath.
/// The breathing rhythm (`pingPulseCount`, `pingPulsePeriod`) stays the same at every level.
enum GlowIntensity: String, CaseIterable, Identifiable {
    case subtle, normal, bright

    static let storageKey = "pingGlowIntensity"
    static let defaultValue = GlowIntensity.normal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .bright: return "Bright"
        }
    }

    var restLevel: CGFloat {
        switch self {
        case .subtle: return 0.08   // the 1.5 look
        case .normal: return 0.25
        case .bright: return 0.45
        }
    }

    var peakScale: CGFloat {
        switch self {
        case .subtle, .normal: return 1.0
        case .bright: return 1.4
        }
    }

    static func resolved(from rawValue: String?) -> GlowIntensity {
        rawValue.flatMap(GlowIntensity.init(rawValue:)) ?? defaultValue
    }

    /// Opacity of the gradient's centre stop at a given glow level, capped so Bright can
    /// never wash the mascot out entirely.
    func centreOpacity(at glow: CGFloat) -> CGFloat {
        min(0.30 * glow * peakScale, 0.5)
    }
}
