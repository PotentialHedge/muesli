import Foundation

/// Runs the user's `on-meeting-end` executable after a meeting's final pass.
///
/// It gets the meeting folder as its argument and working directory, and `MUESLI_*` environment
/// variables. Its output goes to a log file. Nothing waits for it, so a slow hook holds nothing up.
public struct MeetingEndHook: Sendable {
    public var executable: URL
    public var log: URL

    public enum Outcome: Sendable, Equatable {
        case notInstalled
        case exited(Int32)
        case couldNotLaunch(String)
    }

    public init(
        executable: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/muesli/hooks/on-meeting-end"),
        log: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Muesli/on-meeting-end.log")
    ) {
        self.executable = executable
        self.log = log
    }

    /// Returns when the hook exits.
    public func run(folder: URL, status: MeetingMetadata.Status) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .notInstalled }

        let process = Process()
        process.executableURL = executable
        process.arguments = [folder.path]
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MUESLI_MEETING_DIR": folder.path,
            "MUESLI_TRANSCRIPT_MD": folder.appendingPathComponent(MeetingFiles.transcript).path,
            "MUESLI_TRANSCRIPT_JSON": folder.appendingPathComponent(MeetingFiles.json).path,
            "MUESLI_STATUS": status.rawValue,
        ]) { _, new in new }
        let output = openLog(for: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: .exited($0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .couldNotLaunch("\(error)"))
            }
        }
    }

    /// Appends to the log. A hook still runs if the log can't be opened.
    private func openLog(for folder: URL) -> FileHandle {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return .nullDevice }
        _ = try? handle.seekToEnd()
        let stamp = Date.now.formatted(.iso8601)
        try? handle.write(contentsOf: Data("--- \(stamp) \(folder.lastPathComponent)\n".utf8))
        return handle
    }
}
