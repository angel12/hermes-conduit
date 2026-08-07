import XCTest
@testable import Conduit

final class TurnStateTests: XCTestCase {
    func testGatewayRunningMapsToAuthoritativeComposerStates() {
        XCTAssertEqual(TurnState.fromGatewayRunning(true), .running)
        XCTAssertEqual(TurnState.fromGatewayRunning(false), .idle)
        XCTAssertEqual(TurnState.fromGatewayRunning(nil), .unsupportedGateway)
    }

    func testOnlyResolvedStatesEnableComposerActions() {
        XCTAssertTrue(TurnState.idle.acceptsComposerActions)
        XCTAssertTrue(TurnState.running.acceptsComposerActions)
        XCTAssertFalse(TurnState.synchronizing.acceptsComposerActions)
        XCTAssertFalse(TurnState.reconnecting.acceptsComposerActions)
        XCTAssertFalse(TurnState.unsupportedGateway.acceptsComposerActions)
    }

    func testComposerActionMappingCoversIdleRecoveryAndBusyModes() {
        XCTAssertEqual(TurnState.idle.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .send)
        XCTAssertEqual(TurnState.synchronizing.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
        XCTAssertEqual(TurnState.reconnecting.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
        XCTAssertEqual(TurnState.running.composerAction(hasText: false, hasAttachments: false, busyInputMode: .steer), .stop)
        XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .steer)
        XCTAssertEqual(TurnState.running.composerAction(hasText: true, hasAttachments: false, busyInputMode: .interrupt), .interrupt)
        XCTAssertEqual(TurnState.unsupportedGateway.composerAction(hasText: true, hasAttachments: false, busyInputMode: .steer), .unavailable)
    }

    func testBusyInputModeDefaultsToSteerForUnknownGatewayValues() {
        XCTAssertEqual(BusyInputMode.fromGatewayValue("interrupt"), .interrupt)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("steer"), .steer)
        XCTAssertEqual(BusyInputMode.fromGatewayValue("queue"), .steer)
        XCTAssertEqual(BusyInputMode.fromGatewayValue(nil), .steer)
    }

    func testActiveTurnRedirectOutcomesTreatQueuedAsDelivered() {
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "redirected"), .redirected)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "queued"), .queued)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: "rejected"), .rejected)
        XCTAssertEqual(SessionRedirectOutcome(gatewayStatus: nil), .rejected)
    }

    func testSessionRuntimeSnapshotPreservesGatewayTurnAndRuntimeFields() {
        let snapshot = SessionRuntimeSnapshot(object: [
            "running": .bool(true),
            "status": .string("streaming"),
            "model": .string("gpt-5.6"),
            "provider": .string("openai"),
            "context_percent": .number(42),
            "active_subagents": .number(3)
        ], inflight: .string("message-123"))

        XCTAssertEqual(snapshot.running, true)
        XCTAssertEqual(snapshot.status, "streaming")
        XCTAssertEqual(snapshot.model, "gpt-5.6")
        XCTAssertEqual(snapshot.provider, "openai")
        XCTAssertEqual(snapshot.contextPercent, 42)
        XCTAssertEqual(snapshot.activeAgents, 3)
        XCTAssertEqual(snapshot.inflight?.stringValue, "message-123")
    }
}
