import XCTest
@testable import Conduit

final class SessionCatalogCacheTests: XCTestCase {
    func testRejectsStaleCommitAfterSessionRemoval() {
        var cache = SessionCatalogCache()
        let deleted = SessionSummary(
            id: "deleted-session",
            alternateIds: [],
            title: "Deleted",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        let loadGeneration = cache.mutationGeneration

        XCTAssertTrue(
            cache.commit(
                liveSessions: [deleted],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                loadedFullHistoryKey: "default:exclude",
                at: loadGeneration
            )
        )

        cache.removeSession(withIDs: [deleted.id])

        XCTAssertFalse(
            cache.commit(
                liveSessions: [deleted],
                liveKey: "default:exclude",
                cronSessions: [],
                cronKey: "default:cron",
                loadedFullHistoryKey: "default:exclude",
                at: loadGeneration
            )
        )
        XCTAssertTrue(cache.sessions(forKey: "default:exclude").isEmpty)
    }
}
