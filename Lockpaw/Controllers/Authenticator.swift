import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "Authenticator")

@MainActor
class Authenticator {
    private var activeContext: LAContext?

    /// Authenticate with Touch ID, with password fallback via system dialog.
    func authenticate(reason: String = "Unlock Lockpaw") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password\u{2026}"
        activeContext = context

        defer { if activeContext === context { activeContext = nil } }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.error("Auth not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        // Evaluate off MainActor to avoid deadlock — system dialog needs main thread
        return await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            } catch {
                await MainActor.run {
                    logger.info("Auth cancelled or failed: \(error.localizedDescription)")
                }
                return false
            }
        }.value
    }

    /// Authenticate with macOS password (system dialog, user can click "Use Password").
    func authenticateWithPassword(reason: String = "Enter your password to unlock Lockpaw") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""
        activeContext = context

        defer { if activeContext === context { activeContext = nil } }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.error("Password auth not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        return await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            } catch {
                await MainActor.run {
                    logger.info("Password auth cancelled or failed: \(error.localizedDescription)")
                }
                return false
            }
        }.value
    }

    /// True when this Mac has Touch ID hardware with a finger enrolled. Read fresh each
    /// time — enrolment can change while the app is running.
    var isBiometryAvailable: Bool {
        var error: NSError?
        let available = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if !available {
            logger.info("Biometry unavailable: \(error?.localizedDescription ?? "unknown")")
        }
        return available
    }

    /// Arm the Touch ID sensor with no click first: the evaluation is already in flight
    /// while the screen stays covered, so the first finger press resolves it instead of
    /// asking the user to reach for a button. The system prompt this opens sits behind the
    /// shield-level overlay and is never seen.
    ///
    /// Biometry only. The password fallback stays on `authenticate()`, which needs the
    /// overlay lowered and input unblocked for its dialog — neither of which is safe to do
    /// for the whole locked session.
    func armBiometrics(reason: String = "Unlock Lockpaw") async -> PassiveAuthResult {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        activeContext = context

        defer { if activeContext === context { activeContext = nil } }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            logger.info("Cannot arm Touch ID: \(error?.localizedDescription ?? "unknown")")
            return .failure((error as? LAError)?.code ?? .biometryNotAvailable)
        }

        return await Task.detached { [context] in
            do {
                let authenticated = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                return PassiveAuthResult(authenticated: authenticated, errorCode: nil)
            } catch {
                await MainActor.run {
                    logger.info("Armed Touch ID ended: \(error.localizedDescription)")
                }
                return .failure((error as? LAError)?.code ?? .systemCancel)
            }
        }.value
    }

    func cancelPending() {
        activeContext?.invalidate()
        activeContext = nil
    }
}
