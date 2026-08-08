import Foundation
import XCTest
@testable import Conduit

/// Tests the origin-matching and port-normalization logic used by
/// SecureRedirectDelegate to prevent credential leakage across hosts.
/// The `effectivePort` function handles the WKSecurityOrigin edge case
/// where port 0 means "default for scheme."
final class ConnectionURLPolicyOriginTests: XCTestCase {

    // MARK: - originMatches (URL, URL)

    func testSameOriginMatches() throws {
        let a = URL(string: "https://example.com")
        let b = URL(string: "https://example.com")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testDifferentHostDoesNotMatch() throws {
        let a = URL(string: "https://attacker.com")
        let b = URL(string: "https://example.com")
        XCTAssertFalse(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testDifferentSchemeDoesNotMatch() throws {
        let a = URL(string: "http://example.com")
        let b = URL(string: "https://example.com")
        XCTAssertFalse(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testCaseInsensitiveHost() throws {
        let a = URL(string: "https://EXAMPLE.COM")
        let b = URL(string: "https://example.com")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testCaseInsensitiveScheme() throws {
        let a = URL(string: "HTTPS://example.com")
        let b = URL(string: "https://example.com")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    // MARK: - Port normalization (default ports)

    func testDefaultHTTPPort80MatchesNoPort() throws {
        // https on 443 should match https with no explicit port
        let a = URL(string: "https://example.com:443")
        let b = URL(string: "https://example.com")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testDefaultHTTPPort80MatchesNoPortHTTP() throws {
        let a = URL(string: "http://example.com:80")
        let b = URL(string: "http://example.com")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testDifferentPortDoesNotMatch() throws {
        let a = URL(string: "https://example.com:8443")
        let b = URL(string: "https://example.com")
        XCTAssertFalse(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    func testExplicitSamePortMatches() throws {
        let a = URL(string: "https://example.com:9119")
        let b = URL(string: "https://example.com:9119")
        XCTAssertTrue(ConnectionURLPolicy.originMatches(a, expected: b))
    }

    // MARK: - Port 0 (WKSecurityOrigin edge case)

    func testPort0MatchesDefaultHTTPS() throws {
        // WKSecurityOrigin reports port 0 for default-port connections.
        // This simulates the fix for the Tailscale Serve issue.
        let result = ConnectionURLPolicy.originMatches(
            scheme: "https",
            host: "example.ts.net",
            port: 0,
            expected: URL(string: "https://example.ts.net")
        )
        XCTAssertTrue(result)
    }

    func testPort0MatchesDefaultHTTP() throws {
        let result = ConnectionURLPolicy.originMatches(
            scheme: "http",
            host: "localhost",
            port: 0,
            expected: URL(string: "http://localhost")
        )
        XCTAssertTrue(result)
    }

    func testPort0DoesNotMatchNonDefaultPort() throws {
        let result = ConnectionURLPolicy.originMatches(
            scheme: "https",
            host: "example.com",
            port: 0,
            expected: URL(string: "https://example.com:9119")
        )
        XCTAssertFalse(result)
    }

    func testPort0DoesNotMatchDifferentScheme() throws {
        let result = ConnectionURLPolicy.originMatches(
            scheme: "wss",
            host: "example.com",
            port: 0,
            expected: URL(string: "https://example.com")
        )
        // wss and https both default to 443, so ports match.
        // But schemes differ, so origin should not match.
        XCTAssertFalse(result)
    }

    // MARK: - Nil inputs

    func testNilURLReturnsFalse() {
        XCTAssertFalse(ConnectionURLPolicy.originMatches(nil, expected: URL(string: "https://example.com")))
        XCTAssertFalse(ConnectionURLPolicy.originMatches(URL(string: "https://example.com"), expected: nil))
    }

    func testNilExpectedReturnsFalse() {
        let result = ConnectionURLPolicy.originMatches(
            scheme: "https",
            host: "example.com",
            port: 443,
            expected: nil
        )
        XCTAssertFalse(result)
    }

    // MARK: - URL with embedded credentials (should be rejected upstream)

    func testNormalizedBaseURLRejectsUserInfo() {
        // The normalizer should reject URLs with embedded credentials
        XCTAssertThrowsError(try ConnectionURLPolicy.normalizedBaseURL("https://user:pass@example.com"))
    }

    // MARK: - normalizedBaseURL trailing slash

    func testNormalizedBaseURLStripsTrailingSlashes() throws {
        let normalized = try ConnectionURLPolicy.normalizedBaseURL("https://example.com///")
        XCTAssertEqual(normalized, "https://example.com")
    }

    func testNormalizedBaseURLPreservesPort() throws {
        let normalized = try ConnectionURLPolicy.normalizedBaseURL("https://example.com:9119")
        XCTAssertEqual(normalized, "https://example.com:9119")
    }

    // MARK: - webSocketURL scheme translation

    func testWebSocketURLHTTPToWS() throws {
        let wsURL = try ConnectionURLPolicy.webSocketURL(
            baseURL: "http://localhost:9119",
            path: "/api/ws"
        )
        XCTAssertEqual(wsURL.scheme, "ws")
        XCTAssertTrue(wsURL.absoluteString.contains("/api/ws"))
    }

    func testWebSocketURLHTTPSToWSS() throws {
        let wsURL = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://example.com",
            path: "/api/ws"
        )
        XCTAssertEqual(wsURL.scheme, "wss")
    }

    func testWebSocketURLPreservesGatewayPath() throws {
        let wsURL = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://example.com/gateway",
            path: "/api/ws"
        )
        XCTAssertTrue(wsURL.absoluteString.contains("/gateway/api/ws"))
    }

    func testWebSocketURLWithQueryItems() throws {
        let wsURL = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://example.com",
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: "abc123")]
        )
        XCTAssertEqual(wsURL.query, "ticket=abc123")
    }
}
