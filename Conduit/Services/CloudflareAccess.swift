import Foundation

struct CloudflareAccessKeychainRecord: Codable, Equatable {
    let clientID: String
    let clientSecret: String

    var credentials: CloudflareAccessCredentials? {
        CloudflareAccessCredentials.from(clientID: clientID, clientSecret: clientSecret)
    }
}

struct CloudflareAccessCredentials: Equatable, CustomStringConvertible {
    let clientID: String
    let clientSecret: String

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.isEmpty
    }

    var description: String {
        isConfigured ? "CloudflareAccessCredentials(enabled: true)" : "CloudflareAccessCredentials(enabled: false)"
    }

    func applying(to request: URLRequest) -> URLRequest {
        guard isConfigured else { return request }
        var request = request
        request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return request
    }
}

extension CloudflareAccessCredentials {
    static func from(clientID: String, clientSecret: String) -> CloudflareAccessCredentials? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !clientSecret.isEmpty else { return nil }
        return CloudflareAccessCredentials(clientID: id, clientSecret: clientSecret)
    }
}
