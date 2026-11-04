@preconcurrency import AVFAudio
import Foundation

/// One meeting being recorded: a folder, two tracks (mic = "Me", system = everyone else),
/// and the metadata in `transcript.md`.
///
/// Keeping the tracks separate means we always know which words were yours. Diarization
/// only has to separate the remote speakers.
///
/// With a transcriber, each track is also transcribed live and `transcript.md` grows as the
/// meeting goes on. `finishLiveTranscription()` hands those phrases to the final pass.
@MainActor
public final class RecordingSession {
    public let folder: URL
    public let appID: String?
    public let appName: String?
    public let startedAt: Date
    /// Non-fatal problems, e.g. system audio failed but the mic is recording.
    public private(set) var warnings: [String] = []

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber?
    private let live: LiveTranscript
    private var streams: [Track: TranscriptionStream] = [:]

    public init(store: MeetingStore, app: MeetingApp?, transcriber: Transcriber? = nil, now: Date = .now) throws {
        folder = try store.makeMeetingFolder(start: now, appName: app?.name)
        appID = app?.id
        appName = app?.name
        startedAt = now
        self.transcriber = transcriber
        live = LiveTranscript(
            url: folder.appendingPathComponent(MeetingFiles.transcript),
            metadata: MeetingMetadata(start: now, app: app?.name, status: .recording, language: transcriber?.language)
        )
    }

    public var transcriptURL: URL { folder.appendingPathComponent(MeetingFiles.transcript) }
    public var audioFolder: URL { folder.appendingPathComponent(MeetingFiles.audio, isDirectory: true) }

    public func start() throws {
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        live.update { _ in }

        // Both tracks are written against this clock, so their timelines line up.
        let clockStart = mach_absolute_time()
        var failures = 0
        do {
            try mic.start(url: folder.appendingPathComponent(MeetingFiles.micAudio), clockStart: clockStart, tee: tee(for: .mic))
        } catch {
            failures += 1
            warnings.append("Microphone not recording: \(error)")
        }
        do {
            try system.start(url: folder.appendingPathComponent(MeetingFiles.systemAudio), clockStart: clockStart, tee: tee(for: .system))
        } catch {
            failures += 1
            warnings.append("System audio not recording: \(error)")
        }
        if failures == 2 {
            stop()
            throw RecordingError.nothingToRecord(warnings)
        }
    }

    public func stop(now: Date = .now) {
        mic.stop()
        system.stop()
        if system.secondsWritten == 0, !warnings.contains(where: { $0.hasPrefix("System audio not recording") }) {
            // The tap started but never delivered a buffer: usually permission, so say where to look.
            warnings.append("No system audio was captured, so other participants are missing. Check System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        live.update {
            $0.end = now
            $0.status = .recorded
        }
    }

    /// Waits for live transcription to catch up with the end of the recording. Tracks whose live
    /// transcription failed are left out, so the final pass transcribes them from the file.
    public func finishLiveTranscription() async -> [Track: [Phrase]] {
        var result: [Track: [Phrase]] = [:]
        for (track, stream) in streams {
            do {
                result[track] = try await stream.finish()
            } catch {
                warnings.append("Live transcription of \(track.rawValue) failed: \(error)")
            }
        }
        streams = [:]
        return result
    }

    private func tee(for track: Track) -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard let transcriber else { return nil }
        let live = live
        let stream = transcriber.makeStream { phrase in live.add(phrase, track: track) }
        streams[track] = stream
        return { stream.append($0) }
    }

    /// Seconds of audio captured per track (for diagnostics).
    public func capturedSeconds() -> (mic: Double, system: Double) {
        (mic.secondsWritten, system.secondsWritten)
    }

    /// Last write error per track, if any (for diagnostics).
    public func writeErrors() -> [String] {
        [("mic", mic.writeError), ("system", system.writeError)].compactMap { name, error in
            error.map { "\(name): \($0)" }
        }
    }
}

public enum RecordingError: Error, CustomStringConvertible {
    case nothingToRecord([String])

    public var description: String {
        switch self {
        case .nothingToRecord(let reasons): "Couldn't record anything. " + reasons.joined(separator: " ")
        }
    }
}
