@preconcurrency import AVFAudio
import FluidAudio
import Foundation

/// Scores how likely a stretch of audio is speech, from 0 to 1.
public protocol SpeechDetector: AnyObject {
    /// `block` is mono Float32 at the track's rate, `SpeechGate.blockSeconds` long (except perhaps
    /// the last). Blocks come in order, from one thread at a time.
    func speechProbability(_ block: AVAudioPCMBuffer) -> Float
}

/// Makes a detector for each track file (each keeps its own state).
public typealias SpeechDetectorFactory = @Sendable () -> SpeechDetector

/// Replaces long stretches without speech with digital zeros, which AAC stores in ~4 kbps instead
/// of ~32. Without speech means room noise, typing, a fan: a quiet room is never digital silence,
/// and the encoder spends its full bitrate on the hiss.
///
/// Errs towards keeping audio: the track keeps its length (zeros, not cuts, so tracks stay
/// aligned), speech is untouched, and so are `preRollBlocks` before it and `hangoverBlocks`
/// after it. To keep audio before speech, blocks are held back until a later one decides them,
/// so what comes out lags what goes in by up to `(preRollBlocks + 1) * blockSeconds`.
final class SpeechGate {
    /// Silero's window.
    static let blockSeconds = 0.256
    /// Silero's usual threshold. Below FluidAudio's 0.85 on purpose: missing speech is worse
    /// than keeping noise.
    static let threshold: Float = 0.5
    static let preRollBlocks = 2  // 0.5 s
    static let hangoverBlocks = 6  // 1.5 s

    private let detector: SpeechDetector
    private let format: AVAudioFormat
    private let blockFrames: AVAudioFrameCount
    /// The block being filled.
    private var current: AVAudioPCMBuffer?
    /// Complete blocks without speech, waiting to learn whether speech follows.
    private var held: [AVAudioPCMBuffer] = []
    /// Blocks since the last one with speech; nil before any.
    private var sinceSpeech: Int?

    init(detector: SpeechDetector, format: AVAudioFormat) {
        self.detector = detector
        self.format = format
        blockFrames = AVAudioFrameCount((Self.blockSeconds * format.sampleRate).rounded())
    }

    /// Audio taken in but not yet given out.
    var heldFrames: AVAudioFramePosition {
        AVAudioFramePosition(held.count) * AVAudioFramePosition(blockFrames) + AVAudioFramePosition(current?.frameLength ?? 0)
    }

    /// Takes mono audio in the gate's format. Returns what's decided, in order: new buffers, so
    /// the caller owns them.
    func process(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard let source = buffer.floatChannelData?[0] else { return [] }
        var out: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < Int(buffer.frameLength) {
            guard let block = current ?? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let samples = block.floatChannelData?[0] else { return out }
            let n = min(Int(blockFrames - block.frameLength), Int(buffer.frameLength) - offset)
            (samples + Int(block.frameLength)).update(from: source + offset, count: n)
            block.frameLength += AVAudioFrameCount(n)
            offset += n
            if block.frameLength == blockFrames {
                current = nil
                decide(block, into: &out)
            } else {
                current = block
            }
        }
        return out
    }

    /// At the end: gives out everything held. Nothing follows, so held blocks stay silenced, and
    /// the last partial block goes the way of the block before it.
    func flush() -> [AVAudioPCMBuffer] {
        var out = held.map(Self.silenced)
        held = []
        if let current {
            out.append(isInHangover ? current : Self.silenced(current))
            self.current = nil
        }
        return out
    }

    private var isInHangover: Bool { sinceSpeech.map { $0 <= Self.hangoverBlocks } ?? false }

    private func decide(_ block: AVAudioPCMBuffer, into out: inout [AVAudioPCMBuffer]) {
        if detector.speechProbability(block) >= Self.threshold {
            sinceSpeech = 0
            out += held  // the lead-in
            held = []
            out.append(block)
            return
        }
        sinceSpeech = sinceSpeech.map { $0 + 1 }
        if isInHangover {
            out.append(block)
            return
        }
        held.append(block)
        if held.count > Self.preRollBlocks {
            out.append(Self.silenced(held.removeFirst()))
        }
    }

    private static func silenced(_ block: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        if let samples = block.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(block.frameLength))
        }
        return block
    }
}

/// Silero VAD (via FluidAudio, CoreML on the CPU, ~1 ms per block).
///
/// The model is async; `speechProbability` waits for it, which is fine on the track writer's
/// queue (its ring holds many seconds). If the model fails or stalls, the block counts as speech
/// and is kept.
public final class SileroSpeechDetector: SpeechDetector, @unchecked Sendable {
    private let vad: VadManager
    private var state: VadStreamState
    private let converter = Converter(
        to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VadManager.sampleRate), channels: 1, interleaved: false)!
    )
    /// 16 kHz samples not yet scored: resampled blocks don't come out at exactly 4096.
    private var pending: [Float] = []
    private var lastProbability: Float = 1

    public init(vad: VadManager) {
        self.vad = vad
        state = VadStreamState.initial()
    }

    /// Loads the model, downloading it (~1 MB) the first time, and returns detectors that share it.
    /// On the CPU: the model is small, and the Neural Engine's warm-up isn't worth it.
    public static func load() async throws -> SpeechDetectorFactory {
        AppLogger.minimumLevel = .warning
        let vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        return { SileroSpeechDetector(vad: vad) }
    }

    public func speechProbability(_ block: AVAudioPCMBuffer) -> Float {
        guard let converted = try? converter.convert(block), let samples = converted.floatChannelData?[0] else { return 1 }
        pending += UnsafeBufferPointer(start: samples, count: Int(converted.frameLength))
        var highest: Float?
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            let p = score(chunk)
            highest = max(highest ?? 0, p)
        }
        if let highest { lastProbability = highest }
        return lastProbability
    }

    private final class Outcome: @unchecked Sendable {
        var result: VadStreamResult?
    }

    private func score(_ chunk: [Float]) -> Float {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let (vad, input) = (vad, state)
        Task {
            outcome.result = try? await vad.processStreamingChunk(chunk, state: input)
            done.signal()
        }
        guard done.wait(timeout: .now() + 1) == .success, let result = outcome.result else {
            state = VadStreamState.initial()
            return 1
        }
        state = result.state
        return result.probability
    }
}
