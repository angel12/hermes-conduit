import Foundation

enum DashboardPath {
    static func encodedQueryComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowedCharacters)
    }

    static func withProfile(_ path: String, profile: String) -> String {
        guard profile != "default" else { return path }
        return withExplicitProfile(path, profile: profile)
    }

    static func withExplicitProfile(_ path: String, profile: String) -> String {
        guard !profile.isEmpty,
              let encoded = encodedQueryComponent(profile) else {
            return path
        }
        return "\(path)\(path.contains("?") ? "&" : "?")profile=\(encoded)"
    }

    private static let queryComponentAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()
}
