import Foundation
import XCTest
@testable import Conduit

final class SecurityBoundaryTests: XCTestCase {
    func testRemoteDashboardMustUseHTTPSButLoopbackAndTailscaleMayUseHTTP() throws {
        XCTAssertThrowsError(try ConnectionURLPolicy.normalizedBaseURL("http://gateway.example"))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://gateway.example")))
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://127.0.0.1:9120")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://localhost:9120/"),
            "http://localhost:9120"
        )
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("https://gateway.example/"),
            "https://gateway.example"
        )
        // Tailscale MagicDNS
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://my-server.tailnet-name.ts.net:9121")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://my-server.tailnet-name.ts.net:9121/"),
            "http://my-server.tailnet-name.ts.net:9121"
        )
        // Tailscale CGNAT IP (100.64.0.0/10)
        XCTAssertTrue(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.85.1.2:9121")))
        XCTAssertEqual(
            try ConnectionURLPolicy.normalizedBaseURL("http://100.85.1.2:9121"),
            "http://100.85.1.2:9121"
        )
        // Outside CGNAT range still rejected
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.63.0.1:9121")))
        XCTAssertFalse(ConnectionURLPolicy.isAllowedTransport(URL(string: "http://100.128.0.1:9121")))
    }

    func testWebSocketURLUsesSecureTransportAndPreservesGatewayPath() throws {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: "https://gateway.example/hermes",
            path: "/api/ws",
            queryItems: [URLQueryItem(name: "ticket", value: "one")]
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "gateway.example")
        XCTAssertEqual(url.path, "/hermes/api/ws")
        XCTAssertEqual(url.query, "ticket=one")
    }

    func testProfilePathJoinsExistingQueryAndEscapesSeparators() {
        XCTAssertEqual(DashboardPath.encodedQueryComponent("/tmp/a&b"), "%2Ftmp%2Fa%26b")
        XCTAssertEqual(
            DashboardPath.withProfile("/api/fs/list?path=%2Ftmp", profile: "secondary&unsafe"),
            "/api/fs/list?path=%2Ftmp&profile=secondary%26unsafe"
        )
    }

    func testInlineScriptSerializationEscapesScriptTerminators() {
        let value = MarkupHTML.jsonString("</script>\u{2028}\u{2029}")
        XCTAssertTrue(value.contains("\\u003c/script>"))
        XCTAssertTrue(value.contains("\\u2028"))
        XCTAssertTrue(value.contains("\\u2029"))
    }

    func testDataURLLimitRejectsOversizedBase64BeforeDecoding() {
        XCTAssertFalse(DataURLLimits.isBase64CharacterCountWithinLimit(DataURLLimits.maxBase64Characters + 1))
        XCTAssertTrue(DataURLLimits.isBoundedBase64DataURL("data:image/png;base64,AAAA", prefix: "data:image/"))
    }
}
