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

    func testKeychainRecordRoundTripAndSecretIsNotARepresentation() throws {
        let record = CloudflareAccessKeychainRecord(clientID: "fixture-client", clientSecret: "fixture-client-secret")
        let reloaded = try JSONDecoder().decode(
            CloudflareAccessKeychainRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(reloaded.credentials, CloudflareAccessCredentials(clientID: "fixture-client", clientSecret: "fixture-client-secret"))
        XCTAssertFalse(reloaded.credentials?.description.contains("fixture-client-secret") == true)
        XCTAssertFalse(String(describing: reloaded.credentials).contains("fixture-client-secret"))
    }

    func testIncompleteConfigurationIsAbsent() {
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "client-id", clientSecret: ""))
        XCTAssertNil(CloudflareAccessCredentials.from(clientID: "", clientSecret: "secret"))
    }
}
