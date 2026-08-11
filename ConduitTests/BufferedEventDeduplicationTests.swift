import Foundation
import XCTest
@testable import Conduit

/// Foreground reconciliation buffers stream events while `session.resume`
/// runs, then replays them after the live bubble is seeded from the resume
/// snapshot's cumulative inflight projection. These tests cover the dedupe
/// that keeps replayed deltas from repeating text the snapshot already
/// contains.
final class BufferedEventDeduplicationTests: XCTestCase {

    private func deltaTexts(in events: [StreamEvent]) -> [String] {
        events.compactMap {
            if case .messageDelta(_, let text) = $0 { return text }
            return nil
        }
    }

    // MARK: - overlapLength

    func testOverlapFullCoverage() {
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "Hello world", andPrefixOf: "world"), 5)
    }

    func testOverlapPartialCoverage() {
        // Snapshot ends mid-way through the buffered run.
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "The quick bro", andPrefixOf: "brown fox"), 3)
    }

    func testOverlapNone() {
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "alpha", andPrefixOf: "beta"), 0)
    }

    func testOverlapPrefersLongestMatch() {
        // "aba" occurs twice; the longest suffix/prefix meeting point wins.
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "ababa", andPrefixOf: "ababa"), 5)
    }

    func testOverlapEmptyInputs() {
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "", andPrefixOf: "x"), 0)
        XCTAssertEqual(AppState.overlapLength(betweenSuffixOf: "x", andPrefixOf: ""), 0)
    }

    // MARK: - deduplicatingBufferedEvents

    func testDeltasFullyCoveredBySnapshotAreDropped() {
        // User foregrounds mid-turn; deltas D1+D2 arrive while resume runs,
        // and the snapshot's cumulative inflight already ends with them.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "over the "),
            .messageDelta(sessionId: "s1", text: "lazy dog."),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "The fox jumps over the lazy dog."
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testUncoveredSuffixSurvivesAsSingleDelta() {
        // The snapshot was generated between the two buffered deltas: only
        // the portion beyond the snapshot tail may be replayed.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "over the "),
            .messageDelta(sessionId: "s1", text: "lazy dog."),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "The fox jumps over the lazy"
        )
        XCTAssertEqual(deltaTexts(in: result), [" dog."])
    }

    func testNoOverlapKeepsEventsUntouched() {
        // A gateway whose inflight projection is not cumulative (or a turn
        // that started after the snapshot) must keep its deltas.
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "fresh text"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "unrelated snapshot"
        )
        XCTAssertEqual(deltaTexts(in: result), ["fresh text"])
    }

    func testNonDeltaEventsPassThroughInOrder() {
        let events: [StreamEvent] = [
            .toolStart(sessionId: "s1", toolName: "Bash", toolInput: "ls"),
            .messageDelta(sessionId: "s1", text: "done."),
            .messageComplete(sessionId: "s1", messageId: nil, content: "All done.", reasoning: nil),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "Everything is done."
        )
        XCTAssertEqual(result.count, 2)
        if case .toolStart = result[0] {} else {
            XCTFail("Expected toolStart to pass through first")
        }
        if case .messageComplete = result[1] {} else {
            XCTFail("Expected messageComplete to pass through last")
        }
    }

    func testEmptyInflightKeepsEvents() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "hello"),
        ]
        let result = AppState.deduplicatingBufferedEvents(events, againstInflight: "")
        XCTAssertEqual(deltaTexts(in: result), ["hello"])
    }

    func testRemainderKeepsSessionIdOfBufferedDeltas() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "runtime-42", text: "abc def"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz abc"
        )
        guard case .messageDelta(let sessionId, let text)? = result.first else {
            return XCTFail("Expected a merged delta")
        }
        XCTAssertEqual(sessionId, "runtime-42")
        XCTAssertEqual(text, " def")
    }
}
