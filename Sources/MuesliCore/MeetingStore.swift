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
        /// Audio is being captured; the transcript below grows live.
        case recording
        /// Capture finished; the final pass hasn't run (yet).
        case recorded
        /// Final pass running: transcription of anything missing, diarization.
        case transcribing
        /// Transcript is final.
        case done
        /// Final pass failed; see `error`. Audio is kept so it can be retried.
        case failed
    }

    public var start: Date
    public var end: Date?
    public var app: String?
    public var status: Status
    public var language: String?
    public var speakers: [String]
    public var error: String?

    public init(start: Date, end: Date? = nil, app: String?, status: Status, language: String? = nil,
                speakers: [String] = [], error: String? = nil) {
        self.start = start
        self.end = end
        self.app = app
        self.status = status
        self.language = language
        self.speakers = speakers
        self.error = error
    }

    public func frontmatter() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["---", "date: \(iso.string(from: start))"]
        if let end {
            lines.append("end: \(iso.string(from: end))")
            lines.append("duration: \(Self.duration(end.timeIntervalSince(start)))")
        }
        if let app { lines.append("app: \(Self.yamlString(app))") }
        if let language { lines.append("language: \(language)") }
        if !speakers.isEmpty { lines.append("speakers: [\(speakers.map(Self.yamlString).joined(separator: ", "))]") }
        lines.append("status: \(status.rawValue)")
        if let error { lines.append("error: \(Self.yamlString(error))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads back what `frontmatter()` wrote. Not a general YAML parser: just our own keys.
    public init?(parsing markdown: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var values: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        let iso = ISO8601DateFormatter()
        guard let start = values["date"].flatMap(iso.date(from:)) else { return nil }
        self.start = start
        end = values["end"].flatMap(iso.date(from:))
        app = values["app"].map(Self.unquote)
        status = values["status"].flatMap(Status.init(rawValue:)) ?? .recorded
        language = values["language"]
        error = values["error"].map(Self.unquote)
        if let list = values["speakers"], list.hasPrefix("["), list.hasSuffix("]") {
            speakers = list.dropFirst().dropLast().split(separator: ",")
                .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
        } else {
            speakers = []
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Quote only when needed, so the common case stays readable: `app: Zoom`.
    static func yamlString(_ value: String) -> String {
        let value = value.replacingOccurrences(of: "\n", with: " ")
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || " ._-()".contains($0) }
        if plain, value.first?.isWhitespace == false, value.last?.isWhitespace == false { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
