import XCTest
@testable import Conduit

final class WakePhraseCompilerTests: XCTestCase {
    private let compiler = WakePhraseCompiler(tables: .testFixtures)
    private let defaultKey = WakeProfileKey(gatewayID: "https://hermes.example", profileID: "default")

    func testCompilesEnglishAndChineseWithStableAlias() throws {
        let english = WakePhraseBinding(key: defaultKey, phrase: "  Hey   Conduit ", startsFreshConversation: true)
        let chinese = WakePhraseBinding(
            key: WakeProfileKey(gatewayID: "https://hermes.example", profileID: "chinese"),
            phrase: "小爱同学",
            startsFreshConversation: false
        )

        let compiled = try compiler.compile([english, chinese])

        XCTAssertEqual(compiled[0].phrase, "hey conduit")
        XCTAssertEqual(compiled[0].tokens, ["HH", "EY", "K", "AA", "N", "D", "UW", "IH", "T"])
        XCTAssertEqual(compiled[1].tokens, ["xiao3", "ai4", "tong2", "xue2"])
        XCTAssertEqual(compiled[0].alias, WakePhraseCompiler.stableAlias(for: defaultKey, phrase: "hey conduit"))
        XCTAssertNotEqual(compiled[0].alias, compiled[1].alias)
    }

    func testRejectsDuplicatePhraseAcrossProfiles() {
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "Hey Conduit", startsFreshConversation: true),
            WakePhraseBinding(
                key: WakeProfileKey(gatewayID: "https://hermes.example", profileID: "work"),
                phrase: "hey conduit",
                startsFreshConversation: true
            )
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .duplicatePhrase("hey conduit"))
        }
    }

    func testRejectsWordsAndCharactersOutsideInjectedFixtures() {
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "unknown", startsFreshConversation: true)
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .unsupportedEnglishWord("unknown"))
        }
        XCTAssertThrowsError(try compiler.compile([
            WakePhraseBinding(key: defaultKey, phrase: "你好!", startsFreshConversation: true)
        ])) { error in
            XCTAssertEqual(error as? WakePhraseValidationError, .unsupportedCharacter("!"))
        }
    }
}
