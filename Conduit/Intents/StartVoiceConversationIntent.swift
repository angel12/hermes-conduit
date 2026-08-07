//
//  StartVoiceConversationIntent.swift
//  Conduit
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct ConduitProfileEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conduit profile")
    static var defaultQuery = ConduitProfileEntityQuery()

    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

@available(iOS 16.0, *)
struct ConduitProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ConduitProfileEntity] {
        profiles().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ConduitProfileEntity] { profiles() }

    private func profiles() -> [ConduitProfileEntity] {
        let values = UserDefaults.standard.stringArray(forKey: "conduit.knownProfiles.v1") ?? ["default"]
        let unique = values.reduce(into: [String]()) { result, value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !result.contains(normalized) { result.append(normalized) }
        }
        return (unique.isEmpty ? ["default"] : unique).map {
            ConduitProfileEntity(id: $0, displayName: $0 == "default" ? "Default" : $0)
        }
    }
}

/// Siri deliberately launches Conduit before a microphone is opened. The root
/// scene consumes this pending request once its existing connection is ready.
@available(iOS 16.0, *)
struct StartVoiceConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Conduit"
    static var description = IntentDescription("Open Conduit and start a voice conversation.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Profile") var profile: ConduitProfileEntity?

    init() {}

    init(profile: ConduitProfileEntity?) { self.profile = profile }

    func perform() async throws -> some IntentResult {
        let selectedProfile = profile?.id
        await MainActor.run {
            PendingVoiceIntentStore.shared.enqueue(
                PendingVoiceIntent(profile: selectedProfile, startsFreshConversation: true, source: .siri)
            )
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct ConduitVoiceShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceConversationIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a voice conversation in \(.applicationName)"
            ],
            shortTitle: "Talk to Conduit",
            systemImageName: "mic.fill"
        )
    }
}
