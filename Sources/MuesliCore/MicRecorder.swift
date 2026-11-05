@preconcurrency import AVFAudio
import AVFoundation
import Foundation

/// Records the local microphone ("Me") with Apple's voice processing turned on.
///
/// Voice processing does echo cancellation: without it, if you're not wearing headphones,
/// the mic also picks up the other participants from your speakers, and they'd get
/// transcribed twice, once as "Me".
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?

    public init() {}

    public var secondsWritten: Double { writer?.secondsWritten ?? 0 }
    public var writeError: Error? { writer?.lastError }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(url: URL, clockStart: UInt64? = nil, tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        let format = try prepareInput()
        let writer = try TrackWriter(url: url, inputFormat: format, clockStart: clockStart, tee: tee)
        self.writer = writer
        try capture(format: format, into: writer)
    }

    /// Releases the mic but keeps the track open, so `resume()` carries on in the same file.
    public func pause() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The time paused becomes silence in the track. Does nothing if the track never started.
    public func resume() throws {
        guard let writer else { return }
        let format = try prepareInput()
        try writer.setInput(format)  // the input device may have changed meanwhile
        try capture(format: format, into: writer)
    }

    private func prepareInput() throws -> AVAudioFormat {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // By default voice processing ducks all other audio, which would turn the meeting down.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        return input.outputFormat(forBus: 0)
    }

    private func capture(format: AVAudioFormat, into writer: TrackWriter) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(writing: writer))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    /// Built in a nonisolated static context so the block never inherits an actor.
    private static func tapBlock(writing writer: TrackWriter) -> AVAudioNodeTapBlock {
        { @Sendable buffer, when in writer.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil) }
    }

    public func stop() {
        pause()
        writer?.close()
    }
}
