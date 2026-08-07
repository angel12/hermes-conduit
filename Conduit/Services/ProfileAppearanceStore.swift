//
//  ProfileAppearanceStore.swift
//  Conduit
//
//  Profile presentation is deliberately device-local. Hermes owns the
//  profile identifiers and configuration; a person's chosen label/photo must
//  travel neither to the gateway nor between accounts.
//

import Foundation
import UIKit

enum ProfileAppearanceStore {
    private static let defaultNameKey = "conduit.defaultProfileName.v1"
    private static let avatarsKey = "conduit.profileAvatars.v1"

    static func loadDefaultName() -> String {
        let saved = UserDefaults.standard.string(forKey: defaultNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "Hermes" : saved
    }

    @discardableResult
    static func saveDefaultName(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = normalized.isEmpty ? "Hermes" : normalized
        UserDefaults.standard.set(saved, forKey: defaultNameKey)
        return saved
    }

    static func loadAvatarURLs() -> [String: URL] {
        let paths = UserDefaults.standard.dictionary(forKey: avatarsKey) as? [String: String] ?? [:]
        var restored: [String: URL] = paths.reduce(into: [String: URL]()) { result, entry in
            let url = URL(fileURLWithPath: entry.value)
            if FileManager.default.fileExists(atPath: url.path) { result[entry.key] = url }
        }
        // The image file name encodes the profile, so photos survive a
        // UserDefaults reset or app update even if the small reference map is
        // unavailable. This mirrors the React client's file discovery.
        for directory in [documentsDirectory(), legacyApplicationSupportDirectory()].compactMap({ $0 }) {
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                guard let profile = profileName(from: url), FileManager.default.fileExists(atPath: url.path) else { continue }
                restored[profile] = url
            }
        }
        UserDefaults.standard.set(restored.mapValues(\.path), forKey: avatarsKey)
        return restored
    }

    static func saveAvatar(_ source: Data, for profile: String) throws -> URL {
        guard let image = UIImage(data: source), let jpeg = image.jpegData(compressionQuality: 0.88) else {
            throw ProfileAppearanceError.invalidImage
        }
        let url = try avatarsDirectory().appendingPathComponent(fileName(for: profile), isDirectory: false)
        try jpeg.write(to: url, options: .atomic)
        var paths = UserDefaults.standard.dictionary(forKey: avatarsKey) as? [String: String] ?? [:]
        paths[profile] = url.path
        UserDefaults.standard.set(paths, forKey: avatarsKey)
        return url
    }

    static func removeAvatar(for profile: String) {
        var paths = UserDefaults.standard.dictionary(forKey: avatarsKey) as? [String: String] ?? [:]
        if let path = paths.removeValue(forKey: profile) { try? FileManager.default.removeItem(atPath: path) }
        UserDefaults.standard.set(paths, forKey: avatarsKey)
    }

    private static func avatarsDirectory() throws -> URL {
        let directory = try documentsDirectory(create: true)
        return directory
    }

    private static func documentsDirectory(create: Bool = false) throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
        let directory = base.appendingPathComponent("profile-avatars", isDirectory: true)
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }

    private static func documentsDirectory() -> URL? { try? documentsDirectory(create: false) }

    private static func legacyApplicationSupportDirectory() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        return base.appendingPathComponent("ProfileAvatars", isDirectory: true)
    }

    private static func fileName(for profile: String) -> String {
        let encoded = profile.data(using: .utf8)?.base64EncodedString() ?? "default"
        let safe = encoded.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "profile-\(safe).jpg"
    }

    private static func profileName(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("profile-") else { return nil }
        var encoded = String(stem.dropFirst("profile-".count))
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let name = String(data: data, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }
}

enum ProfileAppearanceError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "That photo could not be read." }
}
