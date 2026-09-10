import Foundation
import LocalAuthentication
import JarvisCore

/// One launch authentication is shared by the encrypted vault and the local services.
/// The system chooses Touch ID when available and offers the Mac password as its secure
/// fallback. Jarvis never receives or stores either credential.
@MainActor enum JarvisAuthentication {
    static let reason = "unlock Jarvis and its encrypted local data"

    static func authenticate() async throws -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = "Use Mac Password"
        context.localizedCancelTitle = "Cancel"
        // This only reuses the same successful Touch ID match for the immediate Keychain
        // operation. It does not weaken the next app launch or persist a credential.
        context.touchIDAuthenticationAllowableReuseDuration = 10

        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            throw JarvisError.message("Touch ID or a Mac login password is required to unlock Jarvis.")
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return context
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel || error.code == .appCancel {
            throw JarvisError.message("Jarvis is locked. Authenticate with Touch ID to continue.")
        } catch {
            throw JarvisError.message("Jarvis could not be unlocked. Try Touch ID again.")
        }
    }
}
