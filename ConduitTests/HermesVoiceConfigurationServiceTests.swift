import XCTest
@testable import Conduit

final class HermesVoiceConfigurationServiceTests: XCTestCase {
    func testParserUsesSchemaProvidersAndProfileConfig() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "research",
            schema: [
                "fields": [
                    ["key": "stt.provider", "options": ["stepfun", "xiaomi_mimo"]],
                    ["key": "tts.provider", "options": [["value": "stepfun"], ["value": "xiaomi_mimo"]]]
                ]
            ],
            config: [
                "stt": ["provider": "xiaomi_mimo", "xiaomi_mimo": ["model": "custom-asr"]],
                "tts": ["provider": "stepfun", "stepfun": ["voice": "custom-voice"]]
            ],
            sttReadiness: ["providers": [["stt_provider": "xiaomi_mimo", "status": "ready", "is_active": true]]],
            ttsReadiness: ["providers": [["tts_provider": "stepfun", "status": "ready", "is_active": true]]],
            environment: [
                "MIMO_API_KEY": ["is_set": true, "redacted_value": "mi…123"],
                "STEPFUN_API_KEY": ["is_set": false, "redacted_value": NSNull()]
            ],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.profile, "research")
        XCTAssertEqual(snapshot.selectedSTTProvider, "xiaomi_mimo")
        XCTAssertEqual(snapshot.selectedTTSProvider, "stepfun")
        XCTAssertEqual(snapshot.values["stt.xiaomi_mimo.model"], "custom-asr")
        XCTAssertEqual(snapshot.values["tts.stepfun.voice"], "custom-voice")
        XCTAssertTrue(snapshot.capability.supportsTranscription)
        XCTAssertTrue(snapshot.capability.supportsSpeech)
        XCTAssertEqual(snapshot.sttProviders.map(\.descriptor.id), ["stepfun", "xiaomi_mimo"])
    }

    func testCredentialMetadataDoesNotCarryRedactedOrSecretValue() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default", schema: nil,
            config: ["stt": [String: Any](), "tts": [String: Any]()],
            sttReadiness: nil, ttsReadiness: nil,
            environment: ["MIMO_API_KEY": ["is_set": true, "redacted_value": "should-not-be-copied", "description": "MiMo key"]],
            sttEndpointAvailable: false, ttsEndpointAvailable: false
        )

        XCTAssertEqual(snapshot.credentials, [.init(key: "MIMO_API_KEY", isSet: true, description: "MiMo key")])
        XCTAssertFalse(snapshot.capability.supportsTranscription)
        XCTAssertFalse(snapshot.capability.supportsSpeech)
        XCTAssertEqual(snapshot.capability.unavailableReason, "This Hermes gateway does not provide voice endpoints. Text chat remains available.")
    }

    func testXiaomiCatalogContainsDocumentedBuiltInVoicesAndManualField() {
        let descriptor = VoiceConfigurationParser.catalogDescriptor(id: "xiaomi_mimo", kind: .tts)
        XCTAssertEqual(descriptor?.voices, ["mimo_default", "冰糖", "茉莉", "苏打", "白桦", "Mia", "Chloe", "Milo", "Dean"])
        let fields = VoiceConfigurationParser.typedFields(id: "xiaomi_mimo", kind: .tts)
        XCTAssertTrue(fields.contains { $0.key == "tts.xiaomi_mimo.voice" })
        XCTAssertTrue(fields.contains { $0.key == "tts.xiaomi_mimo.delivery_instructions" })
    }

    func testStepFunFieldKeysStayInTheProviderSections() {
        let fields = VoiceConfigurationParser.typedFields(id: "stepfun", kind: .tts)
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.endpoint_preset" })
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.endpoint" })
        XCTAssertTrue(fields.contains { $0.key == "tts.stepfun.instruction" })
        XCTAssertTrue(fields.allSatisfy { $0.key.hasPrefix("tts.stepfun.") })
    }

    func testUnsetPluginCredentialStillAppearsFromReadinessMetadata() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["provider": "stepfun"], "tts": ["provider": "stepfun"]],
            sttReadiness: [
                "providers": [[
                    "stt_provider": "stepfun",
                    "status": "needs_keys",
                    "is_active": true,
                    "env_vars": [["key": "STEPFUN_API_KEY", "is_set": false, "prompt": "StepFun API key"]]
                ]]
            ],
            ttsReadiness: ["providers": []],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.credentials, [
            .init(key: "STEPFUN_API_KEY", isSet: false, description: "StepFun API key")
        ])
        XCTAssertFalse(snapshot.capability.supportsTranscription)
    }

    func testLocalWhisperReadinessUsesCanonicalProviderAndVisibleDefaultModel() {
        let snapshot = VoiceConfigurationParser.parse(
            profile: "default",
            schema: nil,
            config: ["stt": ["provider": "local"], "tts": ["provider": "edge"]],
            sttReadiness: [
                "providers": [[
                    "name": "Local Whisper",
                    "status": "ready",
                    "is_active": true,
                    "env_vars": []
                ]]
            ],
            ttsReadiness: [
                "providers": [[
                    "name": "Microsoft Edge TTS",
                    "tts_provider": "edge",
                    "status": "ready",
                    "is_active": true,
                    "env_vars": []
                ]]
            ],
            environment: [:],
            sttEndpointAvailable: true,
            ttsEndpointAvailable: true
        )

        XCTAssertEqual(snapshot.sttProviders.map(\.descriptor.id), ["local"])
        XCTAssertEqual(snapshot.sttProviders.first?.descriptor.displayName, "Local")
        XCTAssertEqual(snapshot.sttProviders.first?.fields.first(where: { $0.key == "stt.local.model" })?.defaultValue, "base")
        XCTAssertTrue(snapshot.capability.supportsTranscription)
    }
}
