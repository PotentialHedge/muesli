import Foundation
import MuesliCore

/// The same binary doubles as a CLI: `Muesli.app/Contents/MacOS/Muesli <command>`.
@MainActor
enum CLI {
    static let commands: Set<String> = ["mic-users", "record", "help", "--help", "-h"]

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "mic-users": return micUsers()
        case "record": return record(Array(args.dropFirst()))
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
            let session = try RecordingSession(store: store, app: nil)
            try session.start()
            session.warnings.forEach { print("warning: \($0)") }
            print("Recording for \(Int(seconds))s into \(session.folder.path)")
            RunLoop.main.run(until: .now + seconds)
            session.stop()
            let captured = session.capturedSeconds()
            print(String(format: "Captured mic %.1fs, system %.1fs", captured.mic, captured.system))
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
