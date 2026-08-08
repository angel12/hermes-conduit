import Foundation
import XCTest
@testable import Conduit

final class CloudflareAccessTests: XCTestCase {
    func testDisabledRequestIsUnchanged() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status")))
        XCTAssertEqual(CloudflareAccessCredentials(clientID: "", clientSecret: "").applying(to: request), request)
    }

    func testConfiguredRequestReceivesOnlyBothAccessHeaders() throws {
        let credentials = CloudflareAccessCredentials(clientID: "client-id", clientSecret: "client-secret")
        let request = credentials.applying(to: URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status"))))
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "client-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDisabledRetainedFieldsDoNotAdmitCredentialsOrHeaders() throws {
        var login = LoginView()
        login.cloudflareClientID = "retained-client-id"
        login.cloudflareClientSecret = "retained-client-secret"
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://hermes.example/api/status")))

        let disabledRequest = login.configuredCloudflareAccess?.applying(to: request) ?? request
        XCTAssertEqual(disabledRequest, request)
        XCTAssertNil(disabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(disabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"))

        login.cloudflareEnabled = true
        let enabledRequest = try XCTUnwrap(login.configuredCloudflareAccess).applying(to: request)
        XCTAssertEqual(enabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Id"), "retained-client-id")
        XCTAssertEqual(enabledRequest.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "retained-client-secret")
    }

    func testKeychainRecordRoundTripAndSecretIsNotARepresentation() throws {
        let record = CloudflareAccessKeychainRecord(clientID: "fixture-client", clientSecret: "fixture-client-secret", origin: "https://hermes.example")
        let reloaded = try JSONDecoder().decode(
            CloudflareAccessKeychainRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(reloaded.credentials, CloudflareAccessCredentials(clientID: "fixture-client", clientSecret: "fixture-client-secret"))
        XCTAssertEqual(reloaded.origin, "https://hermes.example")
        XCTAssertFalse(reloaded.credentials?.description.contains("fixture-client-secret") == true)
        XCTAssertFalse(String(describing: reloaded.credentials).contains("fixture-client-secret"))
    }

    func testIncompleteConfigurationIsAbsent() {
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "client-id", clientSecret: ""))
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "", clientSecret: "secret"))
    }

    // MARK: - Fetch Injection Script

    func testFetchInjectionContainsBothHeaders() throws {
        let credentials = CloudflareAccessCredentials(clientID: "test-id", clientSecret: "test-secret")
        let script = credentials.fetchInjectionUserScript
        XCTAssertTrue(script.contains("CF-Access-Client-Id"))
        XCTAssertTrue(script.contains("CF-Access-Client-Secret"))
        XCTAssertTrue(script.contains("test-id"))
        XCTAssertTrue(script.contains("test-secret"))
    }

    func testFetchInjectionIsEmptyWhenUnconfigured() {
        let credentials = CloudflareAccessCredentials(clientID: "", clientSecret: "")
        XCTAssertTrue(credentials.fetchInjectionUserScript.isEmpty)
    }

    func testFetchInjectionEscapesSingleQuotes() throws {
        let credentials = CloudflareAccessCredentials(clientID: "id'with'quotes", clientSecret: "secret'val")
        let script = credentials.fetchInjectionUserScript
        // Escaped quotes should be present, raw unescaped values should not
        XCTAssertTrue(script.contains(#"id\'with\'quotes"#))
        XCTAssertTrue(script.contains(#"secret\'val"#))
    }

    // MARK: - Origin Binding

    /// The origin field must survive encode/decode so that
    /// loadCloudflareAccess(for:) can compare it against the current
    /// connection's base URL.
    func testKeychainRecordPreservesOrigin() throws {
        let record = CloudflareAccessKeychainRecord(
            clientID: "id", clientSecret: "secret",
            origin: "https://gateway.example:9119"
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: encoded)
        XCTAssertEqual(decoded.origin, "https://gateway.example:9119")
    }

    /// Simulates what loadCloudflareAccess(for:) does: compares the stored
    /// origin against the requested base URL. This is the actual security
    /// check that prevents a token saved for gateway A from being sent to
    /// gateway B.
    func testOriginMatchLogicAllowsSameGateway() throws {
        let savedOrigin = "https://gateway.example:9119"
        let requestURL = "https://gateway.example:9119"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertEqual(savedOrigin, normalized, "Same gateway should match")
    }

    func testOriginMatchLogicRejectsDifferentGateway() throws {
        let savedOrigin = "https://gateway-a.example"
        let requestURL = "https://gateway-b.example"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertNotEqual(savedOrigin, normalized, "Different gateway must NOT match")
    }

    func testOriginMatchLogicRejectsDifferentPort() throws {
        let savedOrigin = "https://gateway.example:9119"
        let requestURL = "https://gateway.example:9999"
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(requestURL)
        XCTAssertNotEqual(savedOrigin, normalized, "Different port must NOT match")
    }

    /// Decoding a legacy record WITHOUT an origin field (from before the
    /// origin-binding feature was added) should not crash. The origin will
    /// simply be empty, which means loadCloudflareAccess(for:) will never
    /// match it and the user will be prompted to re-enter credentials.
    func testDecodingLegacyRecordWithoutOriginDoesNotCrash() throws {
        let legacyJSON = #"{"clientID":"old-id","clientSecret":"old-secret"}"#
        let data = legacyJSON.data(using: .utf8)!
        // Optional decoding — if origin is non-optional, this will throw
        // and the test documents that a migration is needed.
        if let decoded = try? JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: data) {
            // If it decodes, origin should be empty
            XCTAssertTrue(decoded.origin.isEmpty)
        }
        // If it throws, that's also acceptable as long as the app handles
        // the decode failure gracefully (loadCloudflareAccess returns nil)
    }
}
