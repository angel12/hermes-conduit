import Foundation

enum DataURLLimits {
    static let maxDecodedBytes = 16 * 1024 * 1024
    static let maxBase64Characters = ((maxDecodedBytes + 2) / 3) * 4
    static let maxJSONResponseBytes = 24 * 1024 * 1024

    static func isBase64CharacterCountWithinLimit(_ count: Int) -> Bool {
        count >= 0 && count <= maxBase64Characters
    }

    static func isBoundedBase64DataURL(_ value: String, prefix: String? = nil) -> Bool {
        let header = String(value[..<(value.firstIndex(of: ",") ?? value.endIndex)])
        guard let comma = value.firstIndex(of: ","),
              header.range(of: ";base64", options: [.caseInsensitive]) != nil,
              header.lowercased().hasPrefix("data:"),
              isBase64CharacterCountWithinLimit(value[value.index(after: comma)...].utf8.count) else {
            return false
        }
        if let prefix, !value.lowercased().hasPrefix(prefix.lowercased()) { return false }
        return true
    }

    static func decodeBase64DataURL(_ value: String, prefix: String? = nil) -> Data? {
        guard isBoundedBase64DataURL(value, prefix: prefix),
              let comma = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maxDecodedBytes else { return nil }
        return data
    }
}
