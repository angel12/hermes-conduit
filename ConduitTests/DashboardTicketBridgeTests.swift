import XCTest
@testable import Conduit

@MainActor
final class DashboardTicketBridgeTests: XCTestCase {

    func testInvalidatingPendingRequestsResumesThemWithNotReady() async {
        let requests = DashboardTicketBridgePendingRequests()
        let resultTask = Task { @MainActor in
            do {
                _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<[String: Any], Error>) in
                    requests.insert(continuation, for: 1)
                }
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        while requests.count == 0 {
            await Task.yield()
        }

        requests.rejectAll(with: DashboardTicketBridgeError.notReady)

        switch await resultTask.value {
        case .success:
            XCTFail("Invalidation must resume pending requests with an error")
        case .failure(let error as DashboardTicketBridgeError):
            if case .notReady = error {
                // expected
            } else {
                XCTFail("Expected .notReady, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected DashboardTicketBridgeError.notReady, got \(error)")
        }
        XCTAssertEqual(requests.count, 0)
    }
}
