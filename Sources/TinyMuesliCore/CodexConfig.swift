import Foundation

/// Adds tinyMuesli's MCP server to `~/.codex/config.toml`, which the ChatGPT desktop app (through
/// its built-in Codex) and the Codex CLI read their local MCP servers from.
///
/// TOML is edited by hand, not parsed: only the `[mcp_servers.tinymuesli]` table is replaced or
/// added, and every other line is left exactly as it was.
public enum CodexConfig {
    /// The ChatGPT desktop app and the Codex app.
    public static let bundleIdentifiers = ["com.openai.chat", "com.openai.codex"]
    public static let serverName = ClaudeDesktopConfig.serverName

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")
    }

    private static var header: String { "[mcp_servers.\(serverName)]" }

    /// `config` with the server's table set, keeping everything else.
    public static func adding(binaryPath: String, to config: String) -> String {
        let table = [header, "command = \(quoted(binaryPath))", "args = [\"mcp\"]"]
        var lines = removing(from: config)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        return (lines + table).joined(separator: "\n") + "\n"
    }

    public static func contains(_ config: String) -> Bool {
        config.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == header }
    }

    public static func install(binaryPath: String, at url: URL = defaultURL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try adding(binaryPath: binaryPath, to: existing).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func isInstalled(at url: URL = defaultURL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8)).map(contains) ?? false
    }

    /// The lines of `config` without our table (from its header up to the next table header).
    private static func removing(from config: String) -> [String] {
        var result: [String] = []
        var inOurs = false
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOurs = trimmed == header || trimmed.hasPrefix("[mcp_servers.\(serverName).")
            }
            if !inOurs { result.append(line) }
        }
        if result.last == "" { result.removeLast() }
        return result
    }

    /// A TOML basic string.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
