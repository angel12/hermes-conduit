//
//  WakeLifecycleCoordinator.swift
//  Conduit
//

import Foundation

struct WakeLifecycleSnapshot: Equatable {
    var isForegroundActive: Bool
    var isAuthenticated: Bool
    var isGatewayConnected: Bool
    var microphonePermitted: Bool
    var voiceState: VoiceConversationState

    var canArm: Bool {
        isForegroundActive && isAuthenticated && isGatewayConnected && microphonePermitted && voiceState == .idle
    }
}

@MainActor
final class WakeLifecycleCoordinator {
    private let service: WakeWordService
    private(set) var lastFailureReason: String?

    init(service: WakeWordService) { self.service = service }

    var isArmed: Bool { service.isArmed }

    func update(for snapshot: WakeLifecycleSnapshot) {
        guard snapshot.canArm else {
            service.disarm()
            lastFailureReason = nil
            return
        }
        guard !service.isArmed else { return }
        do {
            try service.arm()
            lastFailureReason = nil
        } catch {
            service.disarm()
            lastFailureReason = error.localizedDescription
        }
    }

    /// Call this synchronously when the scene becomes inactive/backgrounded.
    /// It never leaves local microphone capture running outside foreground use.
    func disarmImmediately() {
        service.disarm()
        lastFailureReason = nil
    }
}
