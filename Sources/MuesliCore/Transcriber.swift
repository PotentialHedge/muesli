@preconcurrency import AVFAudio
import Foundation

/// Speech-to-text engine. Apple's `SpeechAnalyzer` today; Parakeet or Whisper could slot in later.
///
/// Every transcription is a stream: feed a track's audio in order from its start, get timed
/// phrases back. Recording feeds it live; `transcribe(file:)` feeds it from disk. One code
/// path, so the live and re-run transcripts can't drift apart.
public protocol Transcriber: Sendable {
    /// BCP-47 language tag the transcriber is using, e.g. "en-US".
    var language: String { get }

    /// `onPhrase` is called (from any thread) as each phrase is finalised.
    func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream
}

public protocol TranscriptionStream: AnyObject, Sendable {
    /// Mono Float32 audio. Safe to call from a realtime audio thread: it only enqueues.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio. Returns every phrase, once the engine has caught up.
    func finish() async throws -> [Phrase]
}

extension Transcriber {
    /// Transcribes a finished track. Reads the file as the engine asks for it, so memory stays flat
    /// for long meetings.
    public func transcribe(file: URL) async throws -> [Phrase] {
        let audio = try AVAudioFile(forReading: file)
        let stream = makeStream(onPhrase: { _ in })
        let format = audio.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)  // 1 s
        // Check the position: reading at end-of-file throws instead of returning zero frames.
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try audio.read(into: buffer)
            if buffer.frameLength == 0 { break }
            stream.append(buffer)
            // Let the engine keep up instead of decoding the whole file into memory first.
            await (stream as? Backpressured)?.waitForCapacity()
        }
        return try await stream.finish()
    }
}

/// Streams that can tell a producer to slow down (only used for files; live audio can't wait).
protocol Backpressured {
    func waitForCapacity() async
}

/// Wrapper so audio buffers can cross into async code. Each buffer is owned by one consumer.
struct SendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
