@preconcurrency import AVFAudio
import CoreAudio
import Foundation

/// Writes one mono audio track to disk as AAC in a CAF container.
///
/// CAF instead of M4A because an M4A is unreadable until it's finalised; if Muesli crashes
/// mid-meeting, the audio in a CAF can still be recovered. Mono, because transcription and
/// diarization don't need stereo.
///
/// Called from audio threads. TODO: move encoding off the realtime thread (ring buffer → writer queue).
public final class TrackWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let inputFormat: AVAudioFormat
    private let tee: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let lock = NSLock()
    private var isClosed = false
    public private(set) var framesWritten: AVAudioFramePosition = 0
    public private(set) var lastError: Error?

    public var secondsWritten: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / file.processingFormat.sampleRate
    }

    /// `inputFormat` must be Float32 (what both Core Audio taps and AVAudioEngine deliver);
    /// any channel count, interleaved or not. Channels are averaged down to mono.
    /// `tee` receives each mono buffer as it's written (for live transcription); it owns the buffer.
    public init(url: URL, inputFormat: AVAudioFormat, tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32 else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported input format \(inputFormat)",
            ])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.inputFormat = inputFormat
        self.tee = tee
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, buffer.frameLength > 0 else { return }
        do {
            let mono = try Self.mixdown(buffer, to: file.processingFormat)
            try file.write(from: mono)
            framesWritten += AVAudioFramePosition(mono.frameLength)
            if let tee {
                // A mono input comes back as-is, and its memory belongs to the audio system: copy it.
                tee(mono === buffer ? try Self.copy(mono) : mono)
            }
        } catch {
            lastError = error
        }
    }

    /// For Core Audio IOProcs, which hand us a raw buffer list in `inputFormat`.
    public func write(bufferList: UnsafePointer<AudioBufferList>) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList, deallocator: nil) else { return }
        write(buffer)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        file.close()
    }

    static func copy(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData
        else { throw CocoaError(.featureUnsupported) }
        copy.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            target[ch].update(from: source[ch], count: Int(buffer.frameLength))
        }
        return copy
    }

    /// Averages all channels into one. Done by hand because AVAudioConverter silently outputs
    /// zeros for channel layouts it doesn't know, like the 3-channel voice-processing input.
    static func mixdown(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1, !buffer.format.isInterleaved { return buffer }

        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData?[0]
        else { throw CocoaError(.featureUnsupported) }

        let scale = 1 / Float(channels)
        if buffer.format.isInterleaved {
            // floatChannelData is nil for interleaved buffers; read the single raw buffer: L R L R ...
            guard let raw = buffer.audioBufferList.pointee.mBuffers.mData else { throw CocoaError(.featureUnsupported) }
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += samples[frame * channels + ch] }
                out[frame] = sum * scale
            }
        } else {
            guard let source = buffer.floatChannelData else { throw CocoaError(.featureUnsupported) }
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += source[ch][frame] }
                out[frame] = sum * scale
            }
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}
