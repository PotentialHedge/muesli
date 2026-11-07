import Foundation

/// Adds tinyMuesli's MCP server to the Claude desktop app's config. Claude's chat (unlike Claude Code)
/// can't do this itself: its agent runs in a VM that can't reach this file or run a macOS binary.
public enum ClaudeDesktopConfig {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    public static let serverName = "tinymuesli"

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notAnObject

        public var description: String {
            "Claude's config file isn't a JSON object, so tinyMuesli left it alone."
        }
    }

    /// `config` with the server set under "mcpServers", keeping everything else. nil or empty: a new config.
    public static func adding(binaryPath: String, to config: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let config, !config.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
                throw Error.notAnObject
            }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": binaryPath, "args": ["mcp"]]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Whether the config at `url` already has the server.
    public static func isInstalled(at url: URL = defaultURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    /// Writes the server into the config at `url`, creating it if needed.
    public static func install(binaryPath: String, at url: URL = defaultURL) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let updated = try adding(binaryPath: binaryPath, to: existing)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, options: .atomic)
    }
}
