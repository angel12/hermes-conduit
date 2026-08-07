//
//  BiometricAuth.swift
//  Conduit
//

import LocalAuthentication

enum BiometricAuth {
    static var isFaceIDAvailable: Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        return context.biometryType == .faceID
    }

    /// Device passcode remains an iOS-provided recovery path after Face ID
    /// cannot authenticate, rather than turning a transient Face ID failure
    /// into a permanent app lockout.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
