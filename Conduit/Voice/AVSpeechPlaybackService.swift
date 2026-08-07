//
//  AVSpeechPlaybackService.swift
//  Conduit
//

import AVFAudio
import Foundation

@MainActor
final class AVSpeechPlaybackService: NSObject, SpeechPlaybackService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var remainder = Data()
    private var pendingBuffers = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var encodedPlayer: AVAudioPlayer?
    private(set) var isPlaying = false

    override init() {
        super.init()
        engine.attach(player)
    }

    func start(sampleRate: Double) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw VoiceAudioError.unavailable("The gateway reported an unsupported PCM format.")
        }
        self.format = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
        isPlaying = true
    }

    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int {
        if format == nil { try start(sampleRate: sampleRate) }
        guard let format, abs(format.sampleRate - sampleRate) < 1 else {
            throw VoiceAudioError.unavailable("The gateway changed PCM sample rates during a stream.")
        }
        remainder.append(data)
        let alignedBytes = remainder.count - (remainder.count % 2)
        guard alignedBytes > 0 else { return 0 }
        let pcm = remainder.prefix(alignedBytes)
        remainder.removeFirst(alignedBytes)
        let frames = AVAudioFrameCount(alignedBytes / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        buffer.frameLength = frames
        guard let destination = buffer.int16ChannelData else { return 0 }
        pcm.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            destination[0].assign(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        pendingBuffers += 1
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.bufferDidDrain() }
        }
        return alignedBytes
    }

    func playEncodedAudioData(_ data: Data) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { throw VoiceAudioError.unavailable("Could not play Hermes fallback speech.") }
        encodedPlayer = player
        isPlaying = true
    }

    func finish() throws {
        // An odd tail is invalid PCM16 and is intentionally discarded rather
        // than shifted into the next response.
        remainder.removeAll(keepingCapacity: true)
    }

    func drain() async {
        guard pendingBuffers > 0 || encodedPlayer != nil else {
            isPlaying = false
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func stop() {
        player.stop()
        encodedPlayer?.stop()
        encodedPlayer = nil
        engine.stop()
        format = nil
        remainder.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        isPlaying = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func bufferDidDrain() {
        pendingBuffers = max(0, pendingBuffers - 1)
        guard pendingBuffers == 0 else { return }
        isPlaying = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension AVSpeechPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.encodedPlayer === player else { return }
            self.encodedPlayer = nil
            self.isPlaying = false
            let waiters = self.drainWaiters
            self.drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
