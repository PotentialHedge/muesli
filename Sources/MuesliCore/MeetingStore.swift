import Foundation

/// The on-disk layout. The filesystem is the API, so this is the contract other tools rely on:
///
///     <root>/2026/11/2026-11-04 1030 Zoom/
///         transcript.md     frontmatter + transcript
///         audio/mic.caf     raw tracks (temporary unless audio retention is on)
///         audio/system.caf
public struct MeetingStore: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings", isDirectory: true)
    }

    public init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
    }

    public static func folderName(start: Date, appName: String?, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        let label = sanitize(appName ?? "Meeting")
        return "\(stamp) \(label)"
    }

    /// Creates a fresh folder for a meeting, adding " (2)", " (3)"... on collisions.
    public func makeMeetingFolder(start: Date, appName: String?, calendar: Calendar = .current) throws -> URL {
        let c = calendar.dateComponents([.year, .month], from: start)
        let month = root
            .appendingPathComponent(String(format: "%04d", c.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", c.month!), isDirectory: true)
        let base = Self.folderName(start: start, appName: appName, calendar: calendar)

        let fm = FileManager.default
        try fm.createDirectory(at: month, withIntermediateDirectories: true)
        var candidate = month.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = month.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    /// Most recent meeting folders first. Names start with a timestamp, so name order is time order.
    public func recentMeetings(limit: Int = 10) -> [URL] {
        func subdirectories(_ url: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        var result: [URL] = []
        for year in subdirectories(root) {
            for month in subdirectories(year) {
                for meeting in subdirectories(month) {
                    result.append(meeting)
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}

/// YAML frontmatter at the top of `transcript.md`.
public struct MeetingMetadata: Sendable, Equatable {
    public enum Status: String, Sendable {
        case recording
        case recorded
    }

    public var start: Date
    public var end: Date?
    public var app: String?
    public var status: Status

    public init(start: Date, end: Date? = nil, app: String?, status: Status) {
        self.start = start
        self.end = end
        self.app = app
        self.status = status
    }

    public func frontmatter() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["---", "date: \(iso.string(from: start))"]
        if let end {
            lines.append("end: \(iso.string(from: end))")
            lines.append("duration: \(Self.duration(end.timeIntervalSince(start)))")
        }
        if let app { lines.append("app: \(app)") }
        lines.append("status: \(status.rawValue)")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
