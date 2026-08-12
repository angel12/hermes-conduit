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

    private func deltaSessionIDs(in events: [StreamEvent]) -> [String] {
        events.compactMap {
            if case .messageDelta(let sessionId, _) = $0 { return sessionId }
            return nil
        }
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
            againstInflight: "The fox jumps over the lazy dog.",
            knownPrefix: "The fox jumps "
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
            againstInflight: "The fox jumps over the lazy",
            knownPrefix: "The fox jumps "
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
            againstInflight: "unrelated snapshot",
            knownPrefix: "The fox jumps "
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
            againstInflight: "Everything is done.",
            knownPrefix: "Everything is "
        )
        XCTAssertEqual(result.count, 2)
        if case .toolStart = result[0] {} else {
            XCTFail("Expected toolStart to pass through first")
        }
        if case .messageComplete = result[1] {} else {
            XCTFail("Expected messageComplete to pass through last")
        }
    }

    func testPartialCoveragePreservesInterleavedEventOrder() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "abcd"),
            .toolStart(sessionId: "s1", toolName: "Bash", toolInput: "ls"),
            .messageDelta(sessionId: "s1", text: "ef"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "abc",
            knownPrefix: ""
        )

        XCTAssertEqual(result.count, 3)
        if case .messageDelta(_, let text) = result[0] {
            XCTAssertEqual(text, "d")
        } else {
            XCTFail("Expected the uncovered first delta before toolStart")
        }
        if case .toolStart = result[1] {} else {
            XCTFail("Expected toolStart to remain between the deltas")
        }
        if case .messageDelta(_, let text) = result[2] {
            XCTAssertEqual(text, "ef")
        } else {
            XCTFail("Expected the second delta after toolStart")
        }
    }

    func testAmbiguousRepeatedTextIsNotDeduplicated() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaa",
            knownPrefix: "aaaa"
        )

        XCTAssertEqual(deltaTexts(in: result), ["aaa"])
    }

    func testExactBoundaryConsumesOnlyNewRepeatedText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaaaa",
            knownPrefix: "aaaa"
        )

        XCTAssertEqual(deltaTexts(in: result), ["a"])
    }

    func testMismatchedInflightSuffixDoesNotDropNewText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "C"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "AB",
            knownPrefix: "A"
        )

        XCTAssertEqual(deltaTexts(in: result), ["C"])
    }

    func testMissingBoundaryDoesNotGuessFromText() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "aaa"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "aaaa",
            knownPrefix: nil
        )

        XCTAssertEqual(deltaTexts(in: result), ["aaa"])
    }

    func testMultipleSessionDeltasAreNotMerged() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "abc"),
            .messageDelta(sessionId: "s2", text: "def"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "abc",
            knownPrefix: ""
        )

        XCTAssertEqual(deltaSessionIDs(in: result), ["s1", "s2"])
        XCTAssertEqual(deltaTexts(in: result), ["abc", "def"])
    }

    func testEmptyInflightKeepsEvents() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "s1", text: "hello"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "",
            knownPrefix: "prefix"
        )
        XCTAssertEqual(deltaTexts(in: result), ["hello"])
    }

    func testRemainderKeepsSessionIdOfBufferedDeltas() {
        let events: [StreamEvent] = [
            .messageDelta(sessionId: "runtime-42", text: "abc def"),
        ]
        let result = AppState.deduplicatingBufferedEvents(
            events,
            againstInflight: "xyz abc",
            knownPrefix: "xyz "
        )
        guard case .messageDelta(let sessionId, let text)? = result.first else {
            return XCTFail("Expected a merged delta")
        }
        XCTAssertEqual(sessionId, "runtime-42")
        XCTAssertEqual(text, " def")
    }
}
