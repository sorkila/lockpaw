import Foundation

/// User preference: fade the lock screen to pure black after inactivity.
/// Burn-in protection without display sleep — real display sleep is off the table
/// because "require password after display off" locks the GUI session and revokes
/// Accessibility from session apps, killing the hotkey tap and agent automation.
///
/// Two UserDefaults keys, mirroring "Show lock message" + "Message": a checkbox
/// (`enabledKey`, off by default) and the delay picker this enum models.
enum FadeToBlack: String, CaseIterable, Identifiable {
    case afterOneMinute
    case afterFiveMinutes
    case afterTenMinutes

    /// Checkbox: fade to black at all? Off by default.
    static let enabledKey = "fadeToBlackEnabled"
    static let defaultEnabled = false

    /// Delay picker, shown only while enabled.
    static let storageKey = "fadeToBlack"
    static let defaultValue = afterFiveMinutes.rawValue

    var id: String { rawValue }

    /// Idle time before the lock UI fades to black.
    var timeout: TimeInterval {
        switch self {
        case .afterOneMinute: return 60
        case .afterFiveMinutes: return 300
        case .afterTenMinutes: return 600
        }
    }

    var displayName: String {
        switch self {
        case .afterOneMinute: return "1 min"
        case .afterFiveMinutes: return "5 min"
        case .afterTenMinutes: return "10 min"
        }
    }

    static func resolved(from rawValue: String) -> FadeToBlack {
        FadeToBlack(rawValue: rawValue) ?? .afterFiveMinutes
    }

    /// Stored delay preference (falls back to 5 min for unknown/legacy values —
    /// the pre-checkbox build stored "off"/"afterFifteenMinutes" under this key).
    static var current: FadeToBlack {
        resolved(from: UserDefaults.standard.string(forKey: storageKey) ?? defaultValue)
    }

    /// The effective timeout: nil while the checkbox is off. Read once at lock()
    /// time (like multiDisplayMode) — mid-lock changes apply on the next lock.
    static var currentTimeout: TimeInterval? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        return current.timeout
    }
}

/// What the lock overlay is showing. Purely presentational — never consulted by
/// LockState, so no presentation bug can change the security-relevant lock state.
enum LockPresentation: Equatable {
    case visible    // normal lock UI (mascot on primary, ambient blobs on secondaries)
    case black      // pure black, no view subtree mounted
    case attention  // bounded ambient pulse while black (agent ping)
}

/// Everything that can influence presentation while locked.
enum PresentationEvent: Equatable {
    case lockEngaged           // entered .locked (initial lock and re-entry after failed auth)
    case inactivityTimerFired  // blackout or re-black timer elapsed
    case physicalInput         // hardware key/scroll (via InputBlocker) or mouse (via NSEvent monitors)
    case agentPing             // debounced ping that PingDecision said should pulse
    case attentionPulseEnded   // the bounded pulse ran its course
    case errorSurfaced         // lastError set while locked — errors must be visible
    case lockStateLeftLocked   // .unlocking / teardown — the auth UI owns the screen
    case reset                 // stop()
}

/// Which one-shot timer PresentationController currently has armed (reducer input).
enum ArmedTimer: Equatable {
    case blackout      // counting down to fade-to-black
    case reblack       // reveal window after physical input
    case attentionEnd  // bounded attention pulse
}

/// What PresentationController must do with its single timer slot (reducer output).
enum TimerDirective: Equatable {
    case armBlackout(after: TimeInterval)
    case armReblack(after: TimeInterval)
    case armAttentionEnd(after: TimeInterval)
    case cancelAll
    case none  // leave whatever is running untouched
}

struct PresentationDecision: Equatable {
    let presentation: LockPresentation
    let timer: TimerDirective
    let restartsAttentionPulse: Bool
}

/// Pure fade-to-black state machine, kept free of timers, UI, and side effects so
/// every branch can be unit-tested directly (same philosophy as PingDecision).
enum PresentationLogic {
    static func reduce(
        presentation: LockPresentation,
        armed: ArmedTimer?,
        event: PresentationEvent,
        timeout: TimeInterval?
    ) -> PresentationDecision {
        switch event {
        case .lockEngaged:
            guard let timeout else {
                return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
            }
            return PresentationDecision(presentation: .visible, timer: .armBlackout(after: timeout), restartsAttentionPulse: false)

        case .inactivityTimerFired:
            guard presentation == .visible else {  // stale fire
                return PresentationDecision(presentation: presentation, timer: .none, restartsAttentionPulse: false)
            }
            return PresentationDecision(presentation: .black, timer: .none, restartsAttentionPulse: false)

        case .physicalInput:
            switch presentation {
            case .black, .attention:
                guard let timeout else {
                    return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
                }
                return PresentationDecision(
                    presentation: .visible,
                    timer: .armReblack(after: timeout),
                    restartsAttentionPulse: false
                )
            case .visible:
                switch armed {
                case .blackout:
                    guard let timeout else {
                        return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
                    }
                    return PresentationDecision(presentation: .visible, timer: .armBlackout(after: timeout), restartsAttentionPulse: false)
                case .reblack:
                    guard let timeout else {
                        return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
                    }
                    return PresentationDecision(
                        presentation: .visible,
                        timer: .armReblack(after: timeout),
                        restartsAttentionPulse: false
                    )
                case .attentionEnd, nil:
                    // An empty (or foreign) slot arms nothing. This is what suspends
                    // the idle clock during auth — the .unlocking transition cancelled
                    // the slot — and what keeps "off" truly off.
                    return PresentationDecision(presentation: .visible, timer: .none, restartsAttentionPulse: false)
                }
            }

        case .agentPing:
            guard presentation != .visible else {
                // LockScreenView's own glow chain handles pings while visible.
                return PresentationDecision(presentation: .visible, timer: .none, restartsAttentionPulse: false)
            }
            return PresentationDecision(
                presentation: .attention,
                timer: .armAttentionEnd(after: Constants.Timing.attentionPulse),
                restartsAttentionPulse: true
            )

        case .attentionPulseEnded:
            guard presentation == .attention else {  // stale fire
                return PresentationDecision(presentation: presentation, timer: .none, restartsAttentionPulse: false)
            }
            return PresentationDecision(presentation: .black, timer: .none, restartsAttentionPulse: false)

        case .errorSurfaced:
            guard presentation != .visible else {
                return PresentationDecision(presentation: .visible, timer: .none, restartsAttentionPulse: false)
            }
            // Reveal so the error is seen, but keep protection armed — cancelling here
            // would disarm it for the rest of the session when the error path never
            // leaves .locked (e.g. auth rate limiting).
            guard let timeout else {
                return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
            }
            return PresentationDecision(
                presentation: .visible,
                timer: .armReblack(after: timeout),
                restartsAttentionPulse: false
            )

        case .lockStateLeftLocked, .reset:
            return PresentationDecision(presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false)
        }
    }
}
