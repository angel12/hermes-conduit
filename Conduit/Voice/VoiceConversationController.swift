//
//  VoiceConversationController.swift
//  Conduit
//

import Combine
import Foundation

@MainActor
final class VoiceConversationController: ObservableObject {
    struct Configuration: Equatable {
        var voiceActivityThreshold: Float = 0.075
        var trailingSilence: TimeInterval = 1.25
        var idleSilence: TimeInterval = 12
        var maximumUtterance: TimeInterval = 60
        var bargeInDuration: TimeInterval = 0.3
    }

    @Published private(set) var state: VoiceConversationState = .idle
    @Published private(set) var latestTranscript = ""
    @Published private(set) var lastBargeInState: VoiceConversationState?
    @Published private(set) var isOutputMuted = false
    @Published private(set) var isMicrophonePaused = false
    @Published private(set) var conversationTranscript: [VoiceConversationTranscriptEntry] = []
    private var preferences = VoiceProfilePreferences()

    let configuration: Configuration
    private let capture: AudioCaptureService
    private let playback: SpeechPlaybackService
    private let deviceTranscriber: DeviceSpeechTranscriptionService
    private var gateway: VoiceGatewayService?
    private let submit: @MainActor (String) async -> Bool
    private let interrupt: @MainActor () async -> Void
    private var captureEventsTask: Task<Void, Never>?
    private var speechDeltas: [String] = []
    private var isDrainingSpeech = false
    private var speechStream: VoiceSpeechStream?
    private var assistantFinished = false
    private var receivedAssistantDelta = false
    private var utteranceStartedAt: Date?
    private var lastSpeechAt: Date?
    private var bargeInStartedAt: Date?
    private var isForegroundActive = true
    private var isVoiceSessionActive = false
    private var isAwaitingVoiceAssistant = false
    private var awaitedAssistantResponseStarted = false
    private var expectedAssistantSessionID: String?
    private var operationGeneration: UInt64 = 0
    private var utteranceTask: Task<Void, Never>?
    private var bargeInTask: Task<Void, Never>?
    private var speechDrainTask: Task<Void, Never>?
    private var speechDrainRevision: UInt64 = 0
    private var isProviderTestRunning = false
    private var activeAssistantTranscriptEntryID: UUID?

    init(
        capture: AudioCaptureService? = nil,
        playback: SpeechPlaybackService? = nil,
        deviceTranscriber: DeviceSpeechTranscriptionService? = nil,
        gateway: VoiceGatewayService? = nil,
        configuration: Configuration = Configuration(),
        submit: @escaping @MainActor (String) async -> Bool,
        interrupt: @escaping @MainActor () async -> Void
    ) {
        let capture = capture ?? AVAudioCaptureService()
        self.capture = capture
        self.playback = playback ?? AVSpeechPlaybackService()
        self.deviceTranscriber = deviceTranscriber ?? AppleOnDeviceSpeechTranscriber()
        self.gateway = gateway
        self.configuration = configuration
        self.submit = submit
        self.interrupt = interrupt
        captureEventsTask = Task { [weak self, capture] in
            for await event in capture.events {
                guard !Task.isCancelled else { return }
                await self?.handleCaptureEvent(event)
            }
        }
    }

    deinit { captureEventsTask?.cancel() }

    func setGateway(_ gateway: VoiceGatewayService?) { self.gateway = gateway }

    /// Establishes explicit ownership of assistant events for one voice turn.
    /// UI integration should refresh this when a fresh session is created.
    func beginVoiceTurn(sessionID: String) {
        isVoiceSessionActive = true
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        expectedAssistantSessionID = sessionID
        conversationTranscript.removeAll(keepingCapacity: true)
        activeAssistantTranscriptEntryID = nil
    }

    func endVoiceSession() { stop() }

    func setProfilePreferences(_ preferences: VoiceProfilePreferences) {
        self.preferences = preferences
        isOutputMuted = preferences.outputMuted
    }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
        guard !active else { return }
        stop()
    }

    func requestOnDeviceTranscriptionPermissions() async -> VoiceProviderTestResult {
        guard isForegroundActive else {
            return .failure("Voice permissions can only be requested while Conduit is in the foreground.")
        }
        guard await capture.requestPermission() else {
            return .failure(VoiceAudioError.microphonePermissionDenied.localizedDescription)
        }
        guard await deviceTranscriber.requestPermission() else {
            return .failure("Speech Recognition permission is required for on-device transcription.")
        }
        return .success("On-device speech recognition is ready.")
    }

    func startListening(includePreRoll: Bool = false) async {
        guard isForegroundActive else { return }
        let generation = operationGeneration
        isVoiceSessionActive = true
        guard let gateway else { state = .failed("Voice is unavailable for this gateway."); return }
        _ = gateway // keeps the availability check explicit at the state edge.
        guard await capture.requestPermission() else {
            guard isCurrent(generation) else { return }
            state = .failed(VoiceAudioError.microphonePermissionDenied.localizedDescription)
            return
        }
        guard isCurrent(generation) else { return }
        do {
            try capture.startListening(includePreRoll: includePreRoll)
            if isMicrophonePaused { capture.pause() }
            utteranceStartedAt = Date()
            lastSpeechAt = nil
            bargeInStartedAt = nil
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pauseMicrophone() {
        capture.pause()
        isMicrophonePaused = true
    }

    func resumeMicrophone() async {
        guard isForegroundActive else { return }
        if !isMicrophonePaused {
            switch state {
            case .idle, .failed:
                await startListening()
            default:
                break
            }
            return
        }
        guard isVoiceSessionActive else { return }
        do {
            try capture.resume()
            isMicrophonePaused = false
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        operationGeneration &+= 1
        utteranceTask?.cancel()
        utteranceTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        cancelSpeechDrainAndStream()
        capture.stop()
        deviceTranscriber.cancel()
        playback.stop()
        speechDeltas.removeAll()
        assistantFinished = false
        isMicrophonePaused = false
        isVoiceSessionActive = false
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        expectedAssistantSessionID = nil
        state = .idle
    }

    func setOutputMuted(_ muted: Bool) {
        isOutputMuted = muted
        if muted {
            playback.stop()
            cancelSpeechDrainAndStream()
            speechDeltas.removeAll()
            if state == .speaking { state = .muted }
        } else if state == .muted {
            state = .thinking
        }
    }

    /// Records a short sample and transcribes it without creating a chat turn.
    /// This is used exclusively by profile settings to validate the configured
    /// Hermes provider end to end.
    func runTranscriptionTest(duration: TimeInterval = 4) async -> VoiceProviderTestResult {
        stop()
        guard isForegroundActive else {
            return .failure("Voice tests only run while Conduit is in the foreground.")
        }
        guard let gateway else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        isVoiceSessionActive = true
        isProviderTestRunning = true
        let generation = operationGeneration
        defer {
            capture.stop()
            isProviderTestRunning = false
            if isCurrent(generation) { state = .idle }
            isVoiceSessionActive = false
        }
        guard await capture.requestPermission() else {
            return .failure(VoiceAudioError.microphonePermissionDenied.localizedDescription)
        }
        guard isCurrent(generation) else {
            return .failure("The speech-to-text test was cancelled.")
        }
        do {
            try capture.startListening(includePreRoll: false)
            state = .listening
            try await Task.sleep(for: .seconds(duration))
            guard isCurrent(generation) else {
                return .failure("The speech-to-text test was cancelled.")
            }
            let audio = try capture.finishUtterance()
            state = .transcribing
            let transcript = try await transcribe(audio, gateway: gateway)
            guard isCurrent(generation) else {
                return .failure("The speech-to-text test was cancelled.")
            }
            guard !transcript.isEmpty else {
                return .failure("The selected speech-to-text provider returned an empty transcript.")
            }
            latestTranscript = transcript
            return .success("Transcribed: \(transcript)")
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
            return .failure(error.localizedDescription)
        }
    }

    /// Speaks a fixed, non-chat phrase through the same streaming/fallback
    /// transport and playback services used by a conversation.
    func runSpeechTest(text: String) async -> VoiceProviderTestResult {
        stop()
        guard isForegroundActive else {
            return .failure("Voice tests only run while Conduit is in the foreground.")
        }
        guard let gateway else {
            return .failure("Conduit could not connect this test to the selected profile.")
        }
        isVoiceSessionActive = true
        isProviderTestRunning = true
        let generation = operationGeneration
        defer {
            speechStream?.cancel()
            speechStream = nil
            playback.stop()
            isProviderTestRunning = false
            if isCurrent(generation) { state = .idle }
            isVoiceSessionActive = false
        }
        do {
            state = .thinking
            let stream = try await gateway.openSpeechStream(
                onStart: { [weak self] rate in
                    guard let self else { return }
                    try self.playback.start(sampleRate: rate)
                    self.state = .speaking
                },
                onPCM16: { [weak self] data, rate in
                    guard let self else { return }
                    _ = try self.playback.enqueuePCM16(data, sampleRate: rate)
                },
                onEncodedAudio: { [weak self] data in
                    guard let self else { return }
                    try self.playback.playEncodedAudioData(data)
                    self.state = .speaking
                }
            )
            speechStream = stream
            try await stream.append(text)
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            _ = try await stream.finish()
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            try playback.finish()
            await playback.drain()
            guard isCurrent(generation) else {
                return .failure("The speech playback test was cancelled.")
            }
            return .success("Speech playback completed.")
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
            return .failure(error.localizedDescription)
        }
    }

    /// Public for deterministic state-machine tests and for capture services
    /// which coalesce level events differently on route changes.
    func ingestAudioLevel(_ level: Float, at date: Date = Date()) {
        switch state {
        case .listening:
            if utteranceStartedAt == nil { utteranceStartedAt = date }
            if level >= configuration.voiceActivityThreshold { lastSpeechAt = date }
            if let started = utteranceStartedAt, date.timeIntervalSince(started) >= configuration.maximumUtterance {
                scheduleFinishUtterance()
            } else if let speech = lastSpeechAt, date.timeIntervalSince(speech) >= configuration.trailingSilence {
                scheduleFinishUtterance()
            } else if lastSpeechAt == nil, let started = utteranceStartedAt,
                      date.timeIntervalSince(started) >= configuration.idleSilence {
                pauseMicrophone()
            }
        case .thinking, .speaking, .muted:
            if level >= configuration.voiceActivityThreshold {
                if bargeInStartedAt == nil { bargeInStartedAt = date }
                if let started = bargeInStartedAt,
                   date.timeIntervalSince(started) >= configuration.bargeInDuration {
                    scheduleBargeIn()
                }
            } else {
                bargeInStartedAt = nil
            }
        default:
            break
        }
    }

    func receiveAssistantEvent(_ event: VoiceAssistantEvent) {
        let sessionID: String
        switch event {
        case .started(let id), .delta(let id, _), .completed(let id, _),
                .failed(let id, _), .interrupted(let id):
            sessionID = id
        }
        guard isVoiceSessionActive,
              isAwaitingVoiceAssistant,
              let expectedAssistantSessionID,
              sessionID == expectedAssistantSessionID else { return }
        if case .idle = state { return }
        if case .failed = state { return }
        switch event {
        case .started:
            awaitedAssistantResponseStarted = true
            activeAssistantTranscriptEntryID = nil
            receivedAssistantDelta = false
            assistantFinished = false
            speechDeltas.removeAll()
            cancelSpeechDrainAndStream()
            if state == .thinking || state == .muted { beginBargeInMonitoring() }
        case .delta(_, let text):
            awaitedAssistantResponseStarted = true
            receivedAssistantDelta = true
            appendAssistantTranscriptDelta(text)
            guard !isOutputMuted else { return }
            speechDeltas.append(text)
            startSpeechDrainIfNeeded()
        case .completed(_, let content):
            // The gateway emits messageStart before a completion. Ignore a
            // late completion from the assistant turn we intentionally
            // interrupted while waiting for the next turn to begin.
            guard awaitedAssistantResponseStarted else { return }
            completeAssistantTranscript(content)
            // Hermes normally supplies both deltas and a final snapshot. The
            // final snapshot is a recovery value, not another utterance.
            if !receivedAssistantDelta, let content, !isOutputMuted { speechDeltas.append(content) }
            assistantFinished = true
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            startSpeechDrainIfNeeded()
        case .failed(_, let message):
            // A barge-in can produce a terminal cancellation from the prior
            // assistant response after the next user turn has been submitted.
            // It has no message-start/delta for this newly awaited response,
            // so it must not fail the new voice turn.
            guard awaitedAssistantResponseStarted || !isCancellationMessage(message) else { return }
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            state = .failed(message)
            playback.stop()
            cancelSpeechDrainAndStream()
        case .interrupted:
            guard awaitedAssistantResponseStarted else { return }
            isAwaitingVoiceAssistant = false
            awaitedAssistantResponseStarted = false
            playback.stop()
            cancelSpeechDrainAndStream()
            state = .idle
        }
    }

    private func handleCaptureEvent(_ event: VoiceCaptureEvent) {
        if isProviderTestRunning {
            if case .interrupted = event { failForAudioInterruption() }
            return
        }
        switch event {
        case .level(let level, let date): ingestAudioLevel(level, at: date)
        case .interrupted:
            failForAudioInterruption()
        case .routeChanged:
            // AVAudioEngine's tap remains valid across normal Bluetooth/wired
            // route changes. The next capture event re-establishes timing.
            bargeInStartedAt = nil
        }
    }

    private func scheduleFinishUtterance() {
        guard utteranceTask == nil else { return }
        let generation = operationGeneration
        utteranceTask = Task { [weak self] in
            await self?.finishUtterance(generation: generation)
        }
    }

    private func finishUtterance(generation: UInt64) async {
        defer { if operationGeneration == generation { utteranceTask = nil } }
        guard state == .listening, let gateway else { return }
        do {
            let audio = try capture.finishUtterance()
            state = .transcribing
            let transcript = try await transcribe(audio, gateway: gateway)
            guard isCurrent(generation) else { return }
            latestTranscript = transcript
            if transcript.isEmpty {
                await startListening()
                return
            }
            conversationTranscript.append(
                VoiceConversationTranscriptEntry(speaker: .user, text: transcript)
            )
            if isWholeUtteranceStopCommand(transcript) {
                await interrupt()
                guard isCurrent(generation) else { return }
                playback.stop()
                await startListening()
                return
            }
            state = .thinking
            beginBargeInMonitoring()
            // Completion clears ownership for the previous response. Arm the
            // same authoritative session again immediately before each new
            // voice submission so continuous conversation accepts its reply.
            isAwaitingVoiceAssistant = true
            awaitedAssistantResponseStarted = false
            guard await submit(transcript) else {
                guard isCurrent(generation) else { return }
                isAwaitingVoiceAssistant = false
                state = .failed("Hermes could not submit the transcription.")
                return
            }
            guard isCurrent(generation) else { return }
        } catch is CancellationError {
            if isCurrent(generation) { state = .idle }
        } catch {
            if isCurrent(generation) { state = .failed(error.localizedDescription) }
        }
    }

    private func transcribe(_ audio: VoiceCapturedAudio, gateway: VoiceGatewayService) async throws -> String {
        switch preferences.resolvedTranscriptionMode {
        case .hermes:
            return try await gateway.transcribe(audio)
        case .appleOnDevice:
            return try await deviceTranscriber.transcribe(audio)
        }
    }

    private func beginBargeInMonitoring() {
        do {
            try capture.beginBargeInMonitoring()
            if isMicrophonePaused { capture.pause() }
        }
        catch { state = .failed(error.localizedDescription) }
    }

    private func failForAudioInterruption() {
        operationGeneration &+= 1
        utteranceTask?.cancel()
        utteranceTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        cancelSpeechDrainAndStream()
        capture.stop()
        deviceTranscriber.cancel()
        playback.stop()
        speechDeltas.removeAll()
        assistantFinished = false
        isMicrophonePaused = false
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        state = .failed("Audio was interrupted.")
    }

    private func scheduleBargeIn() {
        guard bargeInTask == nil else { return }
        let generation = operationGeneration
        bargeInTask = Task { [weak self] in
            await self?.beginBargeIn(generation: generation)
        }
    }

    private func beginBargeIn(generation: UInt64) async {
        defer { if operationGeneration == generation { bargeInTask = nil } }
        guard state == .thinking || state == .speaking || state == .muted else { return }
        lastBargeInState = state
        playback.stop()
        cancelSpeechDrainAndStream()
        speechDeltas.removeAll()
        assistantFinished = false
        // The in-flight assistant response is intentionally being interrupted.
        // Its terminal event belongs to the retired turn, not the next one.
        isAwaitingVoiceAssistant = false
        awaitedAssistantResponseStarted = false
        await interrupt()
        guard isCurrent(generation) else { return }
        await startListening(includePreRoll: true)
    }

    private func isWholeUtteranceStopCommand(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return preferences.spokenStopPhrases.contains { phrase in
            normalized == phrase.lowercased()
        }
    }

    private func appendAssistantTranscriptDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = activeAssistantTranscriptEntryID,
           let index = conversationTranscript.firstIndex(where: { $0.id == id }) {
            conversationTranscript[index].text += text
            return
        }
        let entry = VoiceConversationTranscriptEntry(speaker: .assistant, text: text)
        activeAssistantTranscriptEntryID = entry.id
        conversationTranscript.append(entry)
    }

    private func completeAssistantTranscript(_ content: String?) {
        if let content, !content.isEmpty {
            if let id = activeAssistantTranscriptEntryID,
               let index = conversationTranscript.firstIndex(where: { $0.id == id }) {
                conversationTranscript[index].text = content
            } else {
                let entry = VoiceConversationTranscriptEntry(speaker: .assistant, text: content)
                conversationTranscript.append(entry)
            }
        }
        activeAssistantTranscriptEntryID = nil
    }

    private func startSpeechDrainIfNeeded() {
        guard !isDrainingSpeech else { return }
        isDrainingSpeech = true
        let operation = operationGeneration
        let revision = speechDrainRevision
        speechDrainTask = Task { [weak self] in
            await self?.drainSpeechQueue(operation: operation, revision: revision)
        }
    }

    private func drainSpeechQueue(operation: UInt64, revision: UInt64) async {
        defer {
            if isSpeechDrainCurrent(operation: operation, revision: revision) {
                isDrainingSpeech = false
                speechDrainTask = nil
            }
        }
        do {
            guard isSpeechDrainCurrent(operation: operation, revision: revision), let gateway else { return }
            if speechStream == nil && !speechDeltas.isEmpty {
                let openedStream = try await gateway.openSpeechStream(
                    onStart: { [weak self] rate in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        try self.playback.start(sampleRate: rate)
                        self.state = .speaking
                        self.beginBargeInMonitoring()
                    },
                    onPCM16: { [weak self] data, rate in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        _ = try self.playback.enqueuePCM16(data, sampleRate: rate)
                    },
                    onEncodedAudio: { [weak self] data in
                        guard let self,
                              self.isSpeechDrainCurrent(operation: operation, revision: revision),
                              !self.isOutputMuted else { return }
                        try self.playback.playEncodedAudioData(data)
                        self.state = .speaking
                        self.beginBargeInMonitoring()
                    }
                )
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else {
                    openedStream.cancel()
                    return
                }
                speechStream = openedStream
            }
            while !speechDeltas.isEmpty, let speechStream, !isOutputMuted {
                try await speechStream.append(speechDeltas.removeFirst())
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            }
            if assistantFinished, let speechStream {
                _ = try await speechStream.finish()
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
                try playback.finish()
                await playback.drain()
                guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
                self.speechStream = nil
            }
        } catch {
            guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            if isSpeechCancellation(error) {
                speechStream = nil
                if assistantFinished {
                    assistantFinished = false
                    await startListening()
                }
                return
            }
            if state == .speaking || state == .thinking { state = .failed(error.localizedDescription) }
            return
        }
        if assistantFinished && speechDeltas.isEmpty && speechStream == nil {
            assistantFinished = false
            guard isSpeechDrainCurrent(operation: operation, revision: revision) else { return }
            await startListening()
        }
    }

    private func cancelSpeechDrainAndStream() {
        speechDrainRevision &+= 1
        let task = speechDrainTask
        let stream = speechStream
        speechDrainTask = nil
        speechStream = nil
        isDrainingSpeech = false
        task?.cancel()
        stream?.cancel()
    }

    private func isSpeechDrainCurrent(operation: UInt64, revision: UInt64) -> Bool {
        isCurrent(operation) && revision == speechDrainRevision
    }

    private func isSpeechCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isCancellationMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("cancelled") || normalized.contains("canceled")
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration && isForegroundActive && isVoiceSessionActive
    }
}
