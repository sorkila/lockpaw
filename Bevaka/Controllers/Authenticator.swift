import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.bevaka", category: "Authenticator")

@MainActor
class Authenticator {
    private var activeContext: LAContext?

    /// Authenticate with Touch ID, with password fallback via system dialog.
    func authenticate(reason: String = "Unlock Bevaka") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password\u{2026}"
        activeContext = context

        defer { activeContext = nil }

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
    func authenticateWithPassword(reason: String = "Enter your password to unlock Bevaka") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""
        activeContext = context

        defer { activeContext = nil }

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

    func cancelPending() {
        activeContext?.invalidate()
        activeContext = nil
    }
}
