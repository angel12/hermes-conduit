//
//  WakeConfigurationStore.swift
//  Conduit
//

import Foundation

struct WakeProfilePreferences: Codable, Equatable {
    var enabledPhrases: [String]
    var startsFreshConversation: Bool

    init(enabledPhrases: [String] = [], startsFreshConversation: Bool = true) {
        self.enabledPhrases = enabledPhrases
        self.startsFreshConversation = startsFreshConversation
    }
}

/// Wake phrases are intentionally device-local: they control local microphone
/// inference and never become Hermes profile configuration.
final class WakeConfigurationStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var values: [WakeProfileKey: WakeProfilePreferences]

    init(defaults: UserDefaults = .standard, storageKey: String = "conduit.wakeConfiguration.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        values = Self.decode(defaults.data(forKey: storageKey))
    }

    func preferences(for key: WakeProfileKey) -> WakeProfilePreferences {
        values[key] ?? WakeProfilePreferences()
    }

    func save(_ preferences: WakeProfilePreferences, for key: WakeProfileKey) {
        values[key] = WakeProfilePreferences(
            enabledPhrases: Self.uniquePhrases(preferences.enabledPhrases),
            startsFreshConversation: preferences.startsFreshConversation
        )
        persist()
    }

    func removePreferences(for key: WakeProfileKey) {
        values.removeValue(forKey: key)
        persist()
    }

    func enabledBindings() -> [WakePhraseBinding] {
        values.flatMap { key, preferences in
            preferences.enabledPhrases.map {
                WakePhraseBinding(key: key, phrase: $0, startsFreshConversation: preferences.startsFreshConversation)
            }
        }
        .sorted { $0.id < $1.id }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(values), forKey: storageKey)
    }

    private static func decode(_ data: Data?) -> [WakeProfileKey: WakeProfilePreferences] {
        guard let data, let decoded = try? JSONDecoder().decode([WakeProfileKey: WakeProfilePreferences].self, from: data) else { return [:] }
        return decoded
    }

    private static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.compactMap { phrase in
            let normalized = WakePhraseCompiler.normalize(phrase)
            return normalized.isEmpty || !seen.insert(normalized).inserted ? nil : normalized
        }
    }
}
