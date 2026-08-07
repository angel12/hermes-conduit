import XCTest
@testable import Conduit

@MainActor
final class WakeLifecycleTests: XCTestCase {
    func testArmsOnlyForForegroundReadyIdleSession() {
        let service = FakeWakeWordService()
        let coordinator = WakeLifecycleCoordinator(service: service)
        let ready = WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            voiceState: .idle
        )

        coordinator.update(for: ready)
        XCTAssertTrue(service.isArmed)
        XCTAssertEqual(service.armCount, 1)

        coordinator.update(for: WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            voiceState: .speaking
        ))
        XCTAssertFalse(service.isArmed)

        coordinator.update(for: WakeLifecycleSnapshot(
            isForegroundActive: false,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            voiceState: .idle
        ))
        XCTAssertFalse(service.isArmed)
        XCTAssertGreaterThanOrEqual(service.disarmCount, 2)
    }

    func testRecordsServiceFailureWithoutLeavingWakeArmed() {
        let service = FakeWakeWordService(error: WakeWordServiceError.unavailable("No model"))
        let coordinator = WakeLifecycleCoordinator(service: service)
        coordinator.update(for: .init(isForegroundActive: true, isAuthenticated: true, isGatewayConnected: true, microphonePermitted: true, voiceState: .idle))
        XCTAssertFalse(service.isArmed)
        XCTAssertEqual(coordinator.lastFailureReason, "No model")
    }

    func testDefaultSherpaAdapterStaysUnavailableBehindPackagingGate() {
        let service = SherpaWakeWordService()
        XCTAssertFalse(service.isArmed)
        XCTAssertEqual(
            service.availability,
            .unavailable(WakeModelDescriptor.bundledBilingualPack.licenseReviewNote)
        )
        XCTAssertThrowsError(try service.arm()) { error in
            XCTAssertEqual(
                error as? WakeWordServiceError,
                .unavailable(WakeModelDescriptor.bundledBilingualPack.licenseReviewNote)
            )
        }
    }

    func testBundledPackMetadataPinsReviewedRuntimeAndArchive() {
        let pack = WakeModelDescriptor.bundledBilingualPack
        XCTAssertEqual(pack.sherpaONNXVersion, "1.13.2")
        XCTAssertEqual(pack.packagingStatus, .blockedPendingLicenseReview)
        XCTAssertEqual(pack.archiveSHA256, "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6")
        XCTAssertEqual(
            pack.assets.prefix(3).map(\.relativePath),
            [
                "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
                "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
                "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx"
            ]
        )
        XCTAssertTrue(pack.assets.allSatisfy { $0.sha256 == nil && $0.checksumStatus == .notRecorded })
    }
}

@MainActor
private final class FakeWakeWordService: WakeWordService {
    var isArmed = false
    var armCount = 0
    var disarmCount = 0
    var error: Error?

    init(error: Error? = nil) { self.error = error }

    func arm() throws {
        armCount += 1
        if let error { throw error }
        isArmed = true
    }

    func disarm() {
        disarmCount += 1
        isArmed = false
    }
}
