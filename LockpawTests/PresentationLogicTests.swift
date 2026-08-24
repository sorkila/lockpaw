import XCTest
@testable import Lockpaw

final class PresentationLogicTests: XCTestCase {
    private let pulse = Constants.Timing.attentionPulse

    private func reduce(
        _ presentation: LockPresentation,
        armed: ArmedTimer? = nil,
        event: PresentationEvent,
        timeout: TimeInterval? = 300
    ) -> PresentationDecision {
        PresentationLogic.reduce(presentation: presentation, armed: armed, event: event, timeout: timeout)
    }

    // MARK: - Lock engaged

    func testLockEngagedArmsEachConfiguredTimeout() {
        for timeout: TimeInterval in [60, 300, 900] {
            let decision = reduce(.visible, event: .lockEngaged, timeout: timeout)
            XCTAssertEqual(decision, PresentationDecision(
                presentation: .visible, timer: .armBlackout(after: timeout), restartsAttentionPulse: false
            ))
        }
    }

    func testLockEngagedWithProtectionOffCancels() {
        let decision = reduce(.visible, event: .lockEngaged, timeout: nil)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false
        ))
    }

    func testLockEngagedForcesVisibleFromBlack() {
        let decision = reduce(.black, armed: .reblack, event: .lockEngaged)
        XCTAssertEqual(decision.presentation, .visible)
        XCTAssertEqual(decision.timer, .armBlackout(after: 300))
    }

    // MARK: - Inactivity timer

    func testInactivityFiredWhileVisibleGoesBlack() {
        let decision = reduce(.visible, armed: .blackout, event: .inactivityTimerFired)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .black, timer: .none, restartsAttentionPulse: false
        ))
    }

    func testInactivityFiredWhileBlackIsStale() {
        let decision = reduce(.black, event: .inactivityTimerFired)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .black, timer: .none, restartsAttentionPulse: false
        ))
    }

    func testInactivityFiredWhileAttentionIsStale() {
        let decision = reduce(.attention, event: .inactivityTimerFired)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .attention, timer: .none, restartsAttentionPulse: false
        ))
    }

    // MARK: - Physical input

    func testPhysicalInputWhileBlackRevealsAndArmsReblack() {
        let decision = reduce(.black, event: .physicalInput)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .armReblack(after: 300), restartsAttentionPulse: false
        ))
    }

    func testPhysicalInputWhileAttentionRevealsAndArmsReblack() {
        let decision = reduce(.attention, armed: .attentionEnd, event: .physicalInput)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .armReblack(after: 300), restartsAttentionPulse: false
        ))
    }

    /// The reveal window is the configured fade delay — the same idle budget as
    /// the initial fade, not a separate constant.
    func testRevealWindowUsesConfiguredTimeout() {
        for timeout: TimeInterval in [60, 300, 900] {
            let decision = reduce(.black, event: .physicalInput, timeout: timeout)
            XCTAssertEqual(decision.timer, .armReblack(after: timeout))
        }
    }

    func testPhysicalInputWhileBlackWithNilTimeoutRevealsAndCancels() {
        let decision = reduce(.black, event: .physicalInput, timeout: nil)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false
        ))
    }

    func testPhysicalInputWhileVisibleWithBlackoutArmedRestartsIdleWindow() {
        let decision = reduce(.visible, armed: .blackout, event: .physicalInput, timeout: 900)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .armBlackout(after: 900), restartsAttentionPulse: false
        ))
    }

    func testPhysicalInputWhileVisibleWithReblackArmedExtendsRevealWindow() {
        let decision = reduce(.visible, armed: .reblack, event: .physicalInput)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .armReblack(after: 300), restartsAttentionPulse: false
        ))
    }

    func testPhysicalInputWithReblackArmedButNilTimeoutCancels() {
        let decision = reduce(.visible, armed: .reblack, event: .physicalInput, timeout: nil)
        XCTAssertEqual(decision.timer, .cancelAll)
    }

    /// The suspension rule: an empty slot arms nothing. This is what keeps the idle
    /// clock stopped during auth (the .unlocking transition cancelled the slot).
    func testPhysicalInputWhileVisibleWithEmptySlotArmsNothing() {
        let decision = reduce(.visible, armed: nil, event: .physicalInput)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .none, restartsAttentionPulse: false
        ))
    }

    func testPhysicalInputWithBlackoutArmedButNilTimeoutCancels() {
        let decision = reduce(.visible, armed: .blackout, event: .physicalInput, timeout: nil)
        XCTAssertEqual(decision.timer, .cancelAll)
    }

    // MARK: - Agent ping

    func testAgentPingWhileBlackStartsAttentionPulse() {
        let decision = reduce(.black, event: .agentPing)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .attention, timer: .armAttentionEnd(after: pulse), restartsAttentionPulse: true
        ))
    }

    func testAgentPingWhileAttentionRestartsPulse() {
        let first = reduce(.black, event: .agentPing)
        let second = reduce(.attention, armed: .attentionEnd, event: .agentPing)
        XCTAssertTrue(first.restartsAttentionPulse)
        XCTAssertTrue(second.restartsAttentionPulse)
        XCTAssertEqual(second.presentation, .attention)
        XCTAssertEqual(second.timer, .armAttentionEnd(after: pulse))
    }

    func testAgentPingWhileVisibleIsNoOp() {
        let decision = reduce(.visible, armed: .blackout, event: .agentPing)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .none, restartsAttentionPulse: false
        ))
    }

    // MARK: - Attention pulse end

    func testAttentionPulseEndedReturnsToBlack() {
        let decision = reduce(.attention, event: .attentionPulseEnded)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .black, timer: .none, restartsAttentionPulse: false
        ))
    }

    func testAttentionPulseEndedWhileVisibleIsStale() {
        let decision = reduce(.visible, armed: .reblack, event: .attentionPulseEnded)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .none, restartsAttentionPulse: false
        ))
    }

    func testAttentionPulseEndedWhileBlackIsStale() {
        let decision = reduce(.black, event: .attentionPulseEnded)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .black, timer: .none, restartsAttentionPulse: false
        ))
    }

    // MARK: - Errors

    func testErrorSurfacedWhileBlackRevealsAndKeepsProtectionArmed() {
        let decision = reduce(.black, event: .errorSurfaced)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .armReblack(after: 300), restartsAttentionPulse: false
        ))
    }

    func testErrorSurfacedWhileAttentionReveals() {
        let decision = reduce(.attention, armed: .attentionEnd, event: .errorSurfaced)
        XCTAssertEqual(decision.presentation, .visible)
        XCTAssertEqual(decision.timer, .armReblack(after: 300))
    }

    func testErrorSurfacedWhileBlackWithNilTimeoutRevealsAndCancels() {
        let decision = reduce(.black, event: .errorSurfaced, timeout: nil)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false
        ))
    }

    func testErrorSurfacedWhileVisibleIsNoOp() {
        let decision = reduce(.visible, armed: .blackout, event: .errorSurfaced)
        XCTAssertEqual(decision, PresentationDecision(
            presentation: .visible, timer: .none, restartsAttentionPulse: false
        ))
    }

    // MARK: - Leaving .locked / reset

    func testLockStateLeftLockedForcesVisibleFromEveryPresentation() {
        for presentation: LockPresentation in [.visible, .black, .attention] {
            let decision = reduce(presentation, armed: .blackout, event: .lockStateLeftLocked)
            XCTAssertEqual(decision, PresentationDecision(
                presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false
            ))
        }
    }

    func testResetForcesVisibleFromEveryPresentation() {
        for presentation: LockPresentation in [.visible, .black, .attention] {
            let decision = reduce(presentation, armed: .attentionEnd, event: .reset)
            XCTAssertEqual(decision, PresentationDecision(
                presentation: .visible, timer: .cancelAll, restartsAttentionPulse: false
            ))
        }
    }

    // MARK: - Invariants & round trips

    /// The pulse restarts on a ping landing while black/attention — and nowhere else.
    func testRestartsAttentionPulseOnlyOnPingWhileNotVisible() {
        let events: [PresentationEvent] = [
            .lockEngaged, .inactivityTimerFired, .physicalInput, .agentPing,
            .attentionPulseEnded, .errorSurfaced, .lockStateLeftLocked, .reset
        ]
        for presentation: LockPresentation in [.visible, .black, .attention] {
            for event in events {
                let decision = reduce(presentation, armed: .blackout, event: event)
                let expected = (event == .agentPing && presentation != .visible)
                XCTAssertEqual(decision.restartsAttentionPulse, expected,
                               "\(presentation) + \(event) should\(expected ? "" : " not") restart the pulse")
            }
        }
    }

    /// Off never arms a timer, whatever happens.
    func testProtectionOffNeverArmsFromAnyEvent() {
        let events: [PresentationEvent] = [
            .lockEngaged, .inactivityTimerFired, .physicalInput, .agentPing,
            .attentionPulseEnded, .errorSurfaced, .lockStateLeftLocked, .reset
        ]
        for event in events {
            let decision = reduce(.visible, armed: nil, event: event, timeout: nil)
            switch decision.timer {
            case .armBlackout, .armReblack:
                XCTFail("Protection off must not arm an idle timer for \(event)")
            case .armAttentionEnd, .cancelAll, .none:
                break  // attention can still bound a pulse; cancel/none are fine
            }
        }
    }

    /// The canonical session: lock → idle → black → ping → attention → pulse end →
    /// black → user returns → visible with a reveal window.
    func testVisibleBlackAttentionBlackRevealRoundTrip() {
        var presentation = LockPresentation.visible
        var armed: ArmedTimer? = nil

        func step(_ event: PresentationEvent) -> PresentationDecision {
            let decision = reduce(presentation, armed: armed, event: event)
            presentation = decision.presentation
            switch decision.timer {
            case .armBlackout: armed = .blackout
            case .armReblack: armed = .reblack
            case .armAttentionEnd: armed = .attentionEnd
            case .cancelAll: armed = nil
            case .none: break
            }
            return decision
        }

        XCTAssertEqual(step(.lockEngaged).timer, .armBlackout(after: 300))
        armed = nil  // one-shot slot empties when it fires
        XCTAssertEqual(step(.inactivityTimerFired).presentation, .black)
        XCTAssertEqual(step(.agentPing).presentation, .attention)
        armed = nil
        XCTAssertEqual(step(.attentionPulseEnded).presentation, .black)
        let reveal = step(.physicalInput)
        XCTAssertEqual(reveal.presentation, .visible)
        XCTAssertEqual(reveal.timer, .armReblack(after: 300))
    }
}
