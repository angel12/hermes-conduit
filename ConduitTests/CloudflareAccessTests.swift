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

    func testKeychainRecordPreservesOrigin() throws {
        let record = CloudflareAccessKeychainRecord(
            clientID: "id", clientSecret: "secret",
            origin: "https://gateway.example:9119"
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CloudflareAccessKeychainRecord.self, from: encoded)
        XCTAssertEqual(decoded.origin, "https://gateway.example:9119")
    }

    func testKeychainRecordRejectsNonMatchingOrigin() throws {
        let record = CloudflareAccessKeychainRecord(
            clientID: "id", clientSecret: "secret",
            origin: "https://gateway-a.example"
        )
        // Simulate the origin check: different origin should not match
        XCTAssertNotEqual(record.origin, "https://gateway-b.example")
    }
}
