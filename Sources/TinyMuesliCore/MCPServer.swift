import Foundation

/// A read-only MCP server over the meeting files: one JSON-RPC message per line on stdin and stdout.
///
/// Written by hand because a few dozen lines of JSON don't justify a dependency in an app that
/// counts its megabytes. It has tools only, no prompts or resources.
///
/// The meetings folder is looked up on every tool call, so a server an agent started earlier
/// follows the folder when it's changed in the app, and says so once.
public final class MCPServer {
    private let root: () -> URL
    public var version: String
    /// The folder the last tool call used.
    private var lastRoot: URL?

    /// Newest first. We use nothing that differs between these, so any of them works.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Always serves `library`'s folder.
    public convenience init(library: MeetingLibrary, version: String = "0") {
        let root = library.store.root
        self.init(root: { root }, version: version)
    }

    /// `root` is asked for the meetings folder before each tool call.
    public init(root: @escaping () -> URL, version: String = "0") {
        self.root = root
        self.version = version
    }

    /// A note for the agent when the folder changed since the last tool call. Ids are relative
    /// to the folder, so they keep working; paths it saw earlier don't.
    private func folderChangeNotice(now current: URL) -> String? {
        defer { lastRoot = current }
        guard let lastRoot, lastRoot.standardizedFileURL.path != current.standardizedFileURL.path else { return nil }
        func name(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
        return "Note: the meetings folder has moved from \(name(lastRoot)) to \(name(current)) since your last call. "
            + "Meeting ids still work; file paths from earlier results are out of date."
    }

    /// Handles one incoming line. Returns the line to send back; notifications get none.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return encoded(error: -32700, "Parse error", id: NSNull())
        }
        guard let message = parsed as? [String: Any], let method = message["method"] as? String else {
            return encoded(error: -32600, "Invalid request", id: (parsed as? [String: Any])?["id"] ?? NSNull())
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        do {
            return encoded(["jsonrpc": "2.0", "id": id, "result": try result(method: method, params: params)])
        } catch let error as RPCError {
            return encoded(error: error.code, error.message, id: id)
        } catch {
            return encoded(error: -32603, "\(error)", id: id)
        }
    }

    /// Runs until stdin closes.
    public func run() {
        while let line = readLine() {
            guard !line.isEmpty, let response = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    private struct RPCError: Error {
        var code: Int
        var message: String
    }

    /// Bad arguments or a missing meeting: reported to the model as a tool result, so it can recover.
    private struct ToolError: Error {
        var message: String
    }

    private func result(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "tinymuesli", "version": version],
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool")
            }
            let current = root()
            let notice = folderChangeNotice(now: current)
            func content(_ text: String) -> [[String: String]] {
                [["type": "text", "text": text]] + (notice.map { [["type": "text", "text": $0]] } ?? [])
            }
            do {
                let text = try call(tool: name, arguments: params["arguments"] as? [String: Any] ?? [:],
                                    library: MeetingLibrary(store: MeetingStore(root: current)))
                return ["content": content(text), "isError": false]
            } catch let error as ToolError {
                return ["content": content(error.message), "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(tool: String, arguments: [String: Any], library: MeetingLibrary) throws -> String {
        switch tool {
        case "list_meetings":
            return try json(library.meetings(limit: arguments["limit"] as? Int ?? 20))
        case "search_transcripts":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError(message: "query is required")
            }
            return try json(library.search(query, limit: arguments["limit"] as? Int ?? 20))
        default:  // get_transcript
            guard let id = arguments["meeting"] as? String else { throw ToolError(message: "meeting is required") }
            guard let folder = library.folder(id: id) else {
                throw ToolError(message: "No meeting with id \"\(id)\". list_meetings gives the ids.")
            }
            let format = arguments["format"] as? String ?? "markdown"
            guard format == "markdown" || format == "json" else { throw ToolError(message: "format must be markdown or json") }
            let file = format == "json" ? MeetingFiles.json : MeetingFiles.transcript
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else {
                throw ToolError(message: "\(file) doesn't exist for this meeting yet. It's written when the final pass finishes; markdown is available during the meeting.")
            }
            return text
        }
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try MeetingLibrary.encoded(value), as: UTF8.self)
    }

    private func encoded(error code: Int, _ message: String, id: Any) -> String? {
        encoded(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encoded(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated(unsafe) private static let tools: [[String: Any]] = [
        tool("list_meetings", "List recorded meetings, most recent first, with their id, time, app, speakers and status. A status of \"recording\" means the meeting is in progress.", properties: [
            "limit": ["type": "integer", "description": "How many to return (default 20)"],
        ]),
        tool("get_transcript", "Read a meeting's transcript. While a meeting is in progress, markdown is available and remote speech is labelled \"Others\".", properties: [
            "meeting": ["type": "string", "description": "Meeting id from list_meetings"],
            "format": ["type": "string", "enum": ["markdown", "json"], "description": "markdown (default): frontmatter and readable turns. json: timed segments."],
        ], required: ["meeting"]),
        tool("search_transcripts", "Find text in all transcripts, ignoring case and accents. Returns the meeting id, speaker, position and surrounding text of each match, newest meetings first.", properties: [
            "query": ["type": "string", "description": "Text to find"],
            "limit": ["type": "integer", "description": "How many matches to return (default 20)"],
        ], required: ["query"]),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": true],
        ]
    }
}
