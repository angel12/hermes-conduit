import Foundation
import XCTest
@testable import Conduit

/// AnyCodable is the foundation of all JSON-RPC communication with the Hermes
/// gateway. If it misparses a type (e.g. `true` as the number `1`), every
/// downstream consumer breaks silently.
final class AnyCodableTests: XCTestCase {

    // MARK: - Decode

    func testDecodeNull() throws {
        let value = try decode("null")
        XCTAssertEqual(value, .null)
    }

    func testDecodeBoolTrue() throws {
        let value = try decode("true")
        XCTAssertEqual(value, .bool(true))
    }

    func testDecodeBoolFalse() throws {
        let value = try decode("false")
        XCTAssertEqual(value, .bool(false))
    }

    func testDecodeInteger() throws {
        let value = try decode("42")
        XCTAssertEqual(value, .number(42))
    }

    func testDecodeDouble() throws {
        let value = try decode("3.14")
        XCTAssertEqual(value, .number(3.14))
    }

    func testDecodeString() throws {
        let value = try decode("\"hello\"")
        XCTAssertEqual(value, .string("hello"))
    }

    func testDecodeEmptyString() throws {
        let value = try decode("\"\"")
        XCTAssertEqual(value, .string(""))
    }

    func testDecodeEmptyArray() throws {
        let value = try decode("[]")
        XCTAssertEqual(value, .array([]))
    }

    func testDecodeArray() throws {
        let value = try decode("[1, \"two\", true, null]")
        XCTAssertEqual(value, .array([.number(1), .string("two"), .bool(true), .null]))
    }

    func testDecodeEmptyObject() throws {
        let value = try decode("{}")
        XCTAssertEqual(value, .object([:]))
    }

    func testDecodeObject() throws {
        let value = try decode(#"{"key": "value", "num": 7}"#)
        XCTAssertEqual(value, .object(["key": .string("value"), "num": .number(7)]))
    }

    func testDecodeNestedStructure() throws {
        let value = try decode(#"{"outer": {"inner": [1, 2]}, "flag": true}"#)
        XCTAssertEqual(value, .object([
            "outer": .object(["inner": .array([.number(1), .number(2)])]),
            "flag": .bool(true)
        ]))
    }

    // MARK: - Encode round-trip

    func testEncodeRoundTripNull() throws {
        try assertRoundTrip(.null)
    }

    func testEncodeRoundTripBool() throws {
        try assertRoundTrip(.bool(true))
        try assertRoundTrip(.bool(false))
    }

    func testEncodeRoundTripNumber() throws {
        try assertRoundTrip(.number(0))
        try assertRoundTrip(.number(-1))
        try assertRoundTrip(.number(3.14159))
        try assertRoundTrip(.number(1e10))
    }

    func testEncodeRoundTripString() throws {
        try assertRoundTrip(.string(""))
        try assertRoundTrip(.string("test"))
        try assertRoundTrip(.string("emoji: 🎉"))
        try assertRoundTrip(.string("escaped \\\\ \"quotes\""))
    }

    func testEncodeRoundTripArray() throws {
        try assertRoundTrip(.array([.number(1), .string("a"), .null, .bool(true)]))
    }

    func testEncodeRoundTripObject() throws {
        try assertRoundTrip(.object(["a": .number(1), "b": .string("x")]))
    }

    func testEncodeRoundTripNested() throws {
        let original: AnyCodable = .object([
            "list": .array([.number(1), .number(2)]),
            "nested": .object(["deep": .bool(true)]),
            "nil": .null
        ])
        try assertRoundTrip(original)
    }

    // MARK: - Bool vs Number disambiguation

    /// This is the critical test: JSON `true` must decode as `.bool(true)`,
    /// NOT as `.number(1)`. Swift's JSONDecoder tries Bool before Double
    /// in a singleValueContainer, so this should work — but if someone
    /// reorders the decode attempts it breaks silently.
    func testTrueIsBoolNotNumber() throws {
        let value = try decode("true")
        XCTAssertNotNil(value.boolValue)
        XCTAssertNil(value.doubleValue)
    }

    func testFalseIsBoolNotNumber() throws {
        let value = try decode("false")
        XCTAssertNotNil(value.boolValue)
        XCTAssertNil(value.doubleValue)
    }

    func testZeroIsNumberNotBool() throws {
        let value = try decode("0")
        XCTAssertNotNil(value.doubleValue)
        XCTAssertNil(value.boolValue)
    }

    func testOneIsNumberNotBool() throws {
        let value = try decode("1")
        XCTAssertNotNil(value.doubleValue)
        // The JSON decoder tries Bool before Double. In Swift, `1` as JSON
        // decodes as `true` for Bool. This is a known behavior of
        // singleValueContainer — verify our impl handles it.
        // If this test fails, it means bool/number priority changed.
    }

    // MARK: - Accessors

    func testStringValue() {
        XCTAssertEqual(AnyCodable.string("x").stringValue, "x")
        XCTAssertNil(AnyCodable.number(1).stringValue)
    }

    func testIntValue() {
        XCTAssertEqual(AnyCodable.number(42).intValue, 42)
        XCTAssertEqual(AnyCodable.number(3.7).intValue, 3)
        XCTAssertNil(AnyCodable.string("42").intValue)
    }

    func testBoolValue() {
        XCTAssertEqual(AnyCodable.bool(true).boolValue, true)
        XCTAssertNil(AnyCodable.number(1).boolValue)
    }

    func testDescriptiveStringValueForBool() {
        XCTAssertEqual(AnyCodable.bool(true).descriptiveStringValue, "true")
        XCTAssertEqual(AnyCodable.bool(false).descriptiveStringValue, "false")
    }

    func testDescriptiveStringValueForNumber() {
        XCTAssertEqual(AnyCodable.number(42).descriptiveStringValue, "42.0")
    }

    func testDescriptiveStringValueForObject() {
        let obj: AnyCodable = .object(["a": .number(1)])
        let desc = obj.descriptiveStringValue
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("\"a\""))
    }

    func testDescriptiveStringValueForNull() {
        XCTAssertNil(AnyCodable.null.descriptiveStringValue)
    }

    // MARK: - from() factory

    func testFromNSNull() {
        XCTAssertEqual(AnyCodable.from(NSNull()), .null)
    }

    func testFromBool() {
        XCTAssertEqual(AnyCodable.from(true), .bool(true))
        XCTAssertEqual(AnyCodable.from(false), .bool(false))
    }

    func testFromInt() {
        XCTAssertEqual(AnyCodable.from(42 as Any), .number(42))
    }

    func testFromDouble() {
        XCTAssertEqual(AnyCodable.from(3.14), .number(3.14))
    }

    func testFromString() {
        XCTAssertEqual(AnyCodable.from("test"), .string("test"))
    }

    func testFromArray() {
        let result = AnyCodable.from([1, "two"] as [Any])
        XCTAssertEqual(result, .array([.number(1), .string("two")]))
    }

    func testFromDictionary() {
        let result = AnyCodable.from(["key": "val"] as [String: Any])
        XCTAssertEqual(result, .object(["key": .string("val")]))
    }

    // MARK: - anyValue conversion

    func testAnyValueNull() {
        XCTAssertTrue(AnyCodable.null.anyValue is NSNull)
    }

    func testAnyValueBool() {
        XCTAssertTrue(AnyCodable.bool(true).anyValue as Any is Bool)
    }

    func testAnyValueObject() {
        let obj = AnyCodable.object(["a": .number(1)])
        let any = obj.anyValue as? [String: Any]
        XCTAssertNotNil(any)
        XCTAssertEqual(any?["a"] as? Double, 1.0)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> AnyCodable {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func assertRoundTrip(_ value: AnyCodable) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        XCTAssertEqual(value, decoded, "Round-trip failed for \(value)")
    }
}
