import Foundation

/// One meeting being recorded: a folder, two tracks (mic = "Me", system = everyone else),
/// and the metadata in `transcript.md`.
///
/// Keeping the tracks separate means we always know which words were yours. Diarization
/// only has to separate the remote speakers.
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
    private var metadata: MeetingMetadata

    public init(store: MeetingStore, app: MeetingApp?, now: Date = .now) throws {
        folder = try store.makeMeetingFolder(start: now, appName: app?.name)
        appID = app?.id
        appName = app?.name
        startedAt = now
        metadata = MeetingMetadata(start: now, app: app?.name, status: .recording)
    }

    public var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    public var audioFolder: URL { folder.appendingPathComponent("audio", isDirectory: true) }

    public func start() throws {
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        try writeMetadata()

        var failures = 0
        do {
            try mic.start(url: audioFolder.appendingPathComponent("mic.caf"))
        } catch {
            failures += 1
            warnings.append("Microphone not recording: \(error)")
        }
        do {
            try system.start(url: audioFolder.appendingPathComponent("system.caf"))
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
        metadata.end = now
        metadata.status = .recorded
        try? writeMetadata()
    }

    /// Seconds of audio captured per track (for diagnostics).
    public func capturedSeconds() -> (mic: Double, system: Double) {
        (mic.secondsWritten, system.secondsWritten)
    }

    private func writeMetadata() throws {
        try metadata.frontmatter().write(to: transcriptURL, atomically: true, encoding: .utf8)
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
