//
//  AVAudioCaptureService.swift
//  Conduit
//

import AVFAudio
import Foundation

@MainActor
final class AVAudioCaptureService: NSObject, AudioCaptureService {
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    /// AVAudioEngine and AVAudioConverter use deinterleaved Float32 as their
    /// canonical PCM representation. Quantize to PCM16 only after resampling.
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var converter: AVAudioConverter?
    private var capturedPCM = Data()
    private var preRollPCM = Data()
    private let maximumPreRollBytes = 16_000 * 2 * 5
    private var activelyRecording = false
    private var paused = false
    private var shouldKeepEngineRunning = false
    private var lastCaptureFailure: String?
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    let events: AsyncStream<VoiceCaptureEvent>

    override init() {
        var capturedContinuation: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch session.recordPermission {
            case .granted:
                continuation.resume(returning: true)
            case .denied:
                continuation.resume(returning: false)
            case .undetermined:
                session.requestRecordPermission { continuation.resume(returning: $0) }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func startListening(includePreRoll: Bool = false) throws {
        try configureSession()
        if !engine.isRunning { try startEngine() }
        capturedPCM = includePreRoll ? preRollPCM : Data()
        lastCaptureFailure = nil
        activelyRecording = true
        paused = false
        shouldKeepEngineRunning = true
    }

    func beginBargeInMonitoring() throws {
        try configureSession()
        if !engine.isRunning { try startEngine() }
        activelyRecording = false
        paused = false
        shouldKeepEngineRunning = true
    }

    func pause() { paused = true }

    func resume() throws {
        try configureSession()
        if !engine.isRunning { try startEngine() }
        paused = false
        shouldKeepEngineRunning = true
    }

    func finishUtterance() throws -> VoiceCapturedAudio {
        activelyRecording = false
        paused = false
        let pcm = capturedPCM
        capturedPCM.removeAll(keepingCapacity: true)
        guard !pcm.isEmpty else {
            if let lastCaptureFailure { throw VoiceAudioError.unavailable(lastCaptureFailure) }
            throw VoiceAudioError.noAudioCaptured
        }
        let duration = Double(pcm.count) / (16_000 * 2)
        return VoiceCapturedAudio(
            wavData: Self.wavWrapping(pcm16: pcm, sampleRate: 16_000),
            pcm16Data: pcm,
            sampleRate: 16_000,
            duration: duration
        )
    }

    func stop() {
        activelyRecording = false
        paused = false
        shouldKeepEngineRunning = false
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw VoiceAudioError.unavailable("The selected microphone is unavailable.")
        }
        converter = nil
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            // AVAudioEngine owns and reuses tap buffers as soon as this block
            // returns. Copy the frame bytes before crossing onto MainActor so
            // conversion never reads a recycled hardware buffer.
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            ) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count, destination.count) {
                guard let sourceData = source[index].mData,
                      let destinationData = destination[index].mData else { continue }
                let byteCount = Int(source[index].mDataByteSize)
                destinationData.copyMemory(from: sourceData, byteCount: byteCount)
                destination[index].mDataByteSize = source[index].mDataByteSize
            }
            Task { @MainActor [weak self] in self?.consume(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard !paused else { return }
        if converter == nil || !Self.converter(converter, accepts: buffer.format) {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else {
            lastCaptureFailure = "The microphone audio format could not be converted."
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            lastCaptureFailure = "Conduit could not allocate a microphone conversion buffer."
            return
        }
        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            lastCaptureFailure = "Microphone conversion failed: \(conversionError.localizedDescription)"
            return
        }
        guard status != .error else {
            lastCaptureFailure = "Microphone conversion failed."
            return
        }
        guard converted.frameLength > 0 else {
            lastCaptureFailure = "The microphone converter produced no audio frames."
            return
        }
        guard let channel = converted.floatChannelData?[0] else {
            lastCaptureFailure = "The microphone converter returned an unsupported sample layout."
            return
        }
        let encoded = VoicePCMEncoding.encode(channel, count: Int(converted.frameLength))
        let pcm = encoded.data
        lastCaptureFailure = nil
        appendPreRoll(pcm)
        if activelyRecording { capturedPCM.append(pcm) }
        continuation?.yield(.level(encoded.peak, date: Date()))
    }

    private func appendPreRoll(_ pcm: Data) {
        preRollPCM.append(pcm)
        if preRollPCM.count > maximumPreRollBytes {
            preRollPCM.removeFirst(preRollPCM.count - maximumPreRollBytes)
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began {
            stop()
            continuation?.yield(.interrupted)
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        // A nil-format tap follows the input node's actual route format. Rebuild
        // the converter lazily without churning an already-running engine.
        converter = nil
        if shouldKeepEngineRunning, !engine.isRunning {
            do { try startEngine() }
            catch { continuation?.yield(.interrupted) }
        }
        continuation?.yield(.routeChanged)
    }

    private static func converter(_ converter: AVAudioConverter?, accepts format: AVAudioFormat) -> Bool {
        guard let input = converter?.inputFormat else { return false }
        return input.commonFormat == format.commonFormat
            && abs(input.sampleRate - format.sampleRate) < 0.5
            && input.channelCount == format.channelCount
            && input.isInterleaved == format.isInterleaved
    }

    private static func wavWrapping(pcm16: Data, sampleRate: Int) -> Data {
        let byteRate = sampleRate * 2
        let fileSize = 36 + pcm16.count
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(fileSize).littleEndianData)
        header.append("WAVEfmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(2).littleEndianData)
        header.append(UInt16(16).littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(pcm16.count).littleEndianData)
        header.append(pcm16)
        return header
    }
}

enum VoicePCMEncoding {
    static func encode(_ samples: UnsafePointer<Float>, count: Int) -> (data: Data, peak: Float) {
        guard count > 0 else { return (Data(), 0) }
        var pcm = [Int16](repeating: 0, count: count)
        var peak: Float = 0
        for index in 0..<count {
            let raw = samples[index]
            let clamped = raw.isFinite ? min(1, max(-1, raw)) : 0
            peak = max(peak, abs(clamped))
            let scaled = clamped >= 0 ? clamped * Float(Int16.max) : clamped * 32_768
            pcm[index] = Int16(scaled.rounded()).littleEndian
        }
        let data = pcm.withUnsafeBytes { Data($0) }
        return (data, peak)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
