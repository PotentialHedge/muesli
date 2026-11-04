import Foundation
import MuesliCore

/// The same binary doubles as a CLI: `Muesli.app/Contents/MacOS/Muesli <command>`.
@MainActor
enum CLI {
    static let commands: Set<String> = ["mic-users", "record", "transcribe", "languages", "help", "--help", "-h"]

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "mic-users": return micUsers()
        case "record": return record(Array(args.dropFirst()))
        case "transcribe": return transcribe(Array(args.dropFirst()))
        case "languages": return languages()
        default:
            print(usage)
            return args.first.map { ["help", "--help", "-h"].contains($0) } == true ? 0 : 1
        }
    }

    static let usage = """
        usage: muesli <command>

          mic-users                 List processes using the microphone and the meeting app each maps to
          record [--seconds N]      Record mic + system audio (default 10s) into a new meeting folder
                 [--root DIR]       Meetings root (default ~/Meetings)
                 [--no-transcribe]  Skip the transcription pass afterwards
          transcribe FOLDER         (Re)run transcription + speaker identification on a meeting folder
                 [--language TAG]   e.g. en-US, de-DE (default: the app's setting, else the system language)
                 [--no-diarize]     Label remote speech "Others" instead of Speaker 1..n
                 [--delete-audio]   Delete audio/ afterwards (kept by default here, so you can re-run)
          languages                 List transcription languages supported on this Mac
        """

    private static func micUsers() -> Int32 {
        do {
            let processes = try AudioProcesses.usingMicrophone()
            if processes.isEmpty { print("No process is using the microphone.") }
            for p in processes {
                let app = MeetingApps.match(bundleID: p.bundleID).map { "→ \($0.name)" } ?? "(not a meeting app)"
                print("\(p.pid)\t\(p.bundleID.isEmpty ? "-" : p.bundleID)\t\(p.name)\t\(app)")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func record(_ args: [String]) -> Int32 {
        var seconds: TimeInterval = 10
        var transcribe = true
        var store = MeetingStore()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--seconds" where i + 1 < args.count:
                seconds = TimeInterval(args[i + 1]) ?? seconds
                i += 2
            case "--root" where i + 1 < args.count:
                store = MeetingStore(root: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                i += 2
            case "--no-transcribe":
                transcribe = false
                i += 1
            default:
                print(usage)
                return 1
            }
        }

        var granted: Bool?
        Task { granted = await MicRecorder.requestPermission() }
        while granted == nil { RunLoop.main.run(until: .now + 0.1) }
        if granted == false { print("warning: no microphone permission; mic track will be silent") }

        do {
            let transcriber = transcribe ? wait { try? await AppleSpeechTranscriber.make(preferred: Settings.language) } : nil
            let session = try RecordingSession(store: store, app: nil, transcriber: transcriber)
            try session.start()
            session.warnings.forEach { print("warning: \($0)") }
            print("Recording for \(Int(seconds))s into \(session.folder.path)")
            RunLoop.main.run(until: .now + seconds)
            session.stop()
            let captured = session.capturedSeconds()
            print(String(format: "Captured mic %.1fs, system %.1fs", captured.mic, captured.system))
            guard let transcriber else { return 0 }

            print("Transcribing…")
            let processor = MeetingProcessor(transcriber: transcriber, diarizer: FluidDiarizer(), keepAudio: true)
            let folder = session.folder
            let result = try wait { () async throws -> MeetingProcessor.Result in
                let live = await session.finishLiveTranscription()
                return try await processor.process(folder: folder, live: live, log: { print($0) })
            }
            result.warnings.forEach { print("warning: \($0)") }
            print("Wrote \(result.document.segments.count) segments, speakers: \(result.document.speakers.joined(separator: ", "))")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func transcribe(_ args: [String]) -> Int32 {
        var folder: URL?
        var language: Locale? = Settings.language
        var diarize = true
        var keepAudio = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--language" where i + 1 < args.count:
                language = Locale(identifier: args[i + 1])
                i += 2
            case "--no-diarize":
                diarize = false
                i += 1
            case "--delete-audio":
                keepAudio = false
                i += 1
            case let arg where !arg.hasPrefix("-") && folder == nil:
                folder = URL(fileURLWithPath: arg, isDirectory: true)
                i += 1
            default:
                print(usage)
                return 1
            }
        }
        guard let folder else {
            print(usage)
            return 1
        }

        do {
            let started = Date()
            let (language, diarize, keepAudio) = (language, diarize, keepAudio)
            let result = try wait { () async throws -> MeetingProcessor.Result in
                let transcriber = try await AppleSpeechTranscriber.make(preferred: language)
                print("Language: \(transcriber.language)")
                let processor = MeetingProcessor(
                    transcriber: transcriber,
                    diarizer: diarize ? FluidDiarizer() : nil,
                    keepAudio: keepAudio
                )
                return try await processor.process(folder: folder, log: { print($0) })
            }
            result.warnings.forEach { print("warning: \($0)") }
            print(String(format: "Wrote %d segments in %.1fs, speakers: %@", result.document.segments.count,
                         Date().timeIntervalSince(started), result.document.speakers.joined(separator: ", ")))
            print(folder.appendingPathComponent(MeetingFiles.transcript).path)
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func languages() -> Int32 {
        let locales = wait { await AppleSpeechTranscriber.offeredLocales() }
        for locale in locales {
            print("\(locale.identifier(.bcp47))\t\(Locale.current.localizedString(forIdentifier: locale.identifier) ?? "")")
        }
        return 0
    }

    /// Runs async work from the synchronous CLI entry point, keeping the main run loop alive.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: .now + 0.05) }
        return try result!.get()
    }

    private static func wait<T>(_ work: @escaping @Sendable () async -> T) -> T {
        try! wait { () async throws -> T in await work() }
    }
}
