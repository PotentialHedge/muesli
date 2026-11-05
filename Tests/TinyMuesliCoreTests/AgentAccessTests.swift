import Foundation
import Testing
@testable import TinyMuesliCore

/// A meetings root with one finished meeting and one in progress.
private func makeLibrary() throws -> MeetingLibrary {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-library-\(UUID().uuidString)")
    func add(_ name: String, status: MeetingMetadata.Status, body: String, json: Bool = false) throws {
        let folder = root.appendingPathComponent("2026/11/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let metadata = MeetingMetadata(start: start, app: "Zoom", status: status, language: "en-US", speakers: ["Me", "Speaker 1"])
        try (metadata.frontmatter() + "\n" + body + "\n").write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
        if json { try "{\"version\":1}".write(to: folder.appendingPathComponent(MeetingFiles.json), atomically: true, encoding: .utf8) }
    }
    try add("2026-11-03 0900 Zoom", status: .done, body: "**Me** [00:00:01] The Café budget is approved.\n\n**Speaker 1** [00:01:05] Great, ship it.", json: true)
    try add("2026-11-04 1030 Zoom", status: .recording, body: "**Others** [00:00:02] Is the budget final?")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/11/2026-11-04 1100 Empty"), withIntermediateDirectories: true)
    return MeetingLibrary(store: MeetingStore(root: root))
}

@Suite struct MeetingLibraryTests {
    @Test func listsMeetingsNewestFirstSkippingFoldersWithoutTranscripts() throws {
        let meetings = try makeLibrary().meetings()
        #expect(meetings.map(\.id) == ["2026/11/2026-11-04 1030 Zoom", "2026/11/2026-11-03 0900 Zoom"])
        #expect(meetings[0].status == "recording")
        #expect(meetings[1].speakers == ["Me", "Speaker 1"])
    }

    @Test func respectsTheLimit() throws {
        #expect(try makeLibrary().meetings(limit: 1).count == 1)
    }

    @Test func searchIgnoresCaseAndAccentsAndCoversMeetingsInProgress() throws {
        let library = try makeLibrary()
        #expect(library.search("BUDGET").map(\.speaker) == ["Others", "Me"])
        let hit = try #require(library.search("cafe").first)
        #expect(hit.meeting == "2026/11/2026-11-03 0900 Zoom")
        #expect(hit.timestamp == "00:00:01")
        #expect(hit.excerpt == "The Café budget is approved.")
        #expect(library.search("budget", limit: 1).count == 1)
        #expect(library.search("   ").isEmpty)
    }

    @Test func excerptsLongParagraphs() throws {
        let text = String(repeating: "a", count: 500) + " needle " + String(repeating: "b", count: 500)
        let excerpt = try #require(MeetingLibrary.excerpt(of: text, around: "needle", radius: 10))
        #expect(excerpt == "…aaaaaaaaa needle bbbbbbbbb…")
    }

    @Test func idsOnlyResolveToExistingMeetings() throws {
        let library = try makeLibrary()
        #expect(library.folder(id: "2026/11/2026-11-03 0900 Zoom") != nil)
        #expect(library.folder(id: "../../../etc") == nil)
        #expect(library.folder(id: "/etc") == nil)
    }
}

@Suite struct MCPServerTests {
    func call(_ server: MCPServer, _ request: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        #expect(!response.contains("\n"))
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func callTool(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let (texts, isError) = try callToolAll(server, name, arguments)
        return (try #require(texts.first), isError)
    }

    /// Every text block of the result, for the folder change notice that follows the answer.
    func callToolAll(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) throws -> (texts: [String], isError: Bool) {
        let response = try call(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (content.compactMap { $0["text"] as? String }, try #require(result["isError"] as? Bool))
    }

    @Test func followsAMovedFolderAndSaysSoOnce() throws {
        let first = try makeLibrary().store.root
        let second = try makeLibrary().store.root
        var current = first
        let server = MCPServer(root: { current })
        let id = "2026/11/2026-11-03 0900 Zoom"

        #expect(try callToolAll(server, "list_meetings", [:]).texts.count == 1)
        try FileManager.default.removeItem(at: first)
        current = second

        let moved = try callToolAll(server, "get_transcript", ["meeting": id])
        #expect(moved.texts.count == 2)
        #expect(moved.texts[0].contains("Great, ship it."))
        #expect(moved.texts[1].contains("meetings folder has moved"))
        #expect(moved.texts[1].contains(second.lastPathComponent))
        #expect(try callToolAll(server, "list_meetings", [:]).texts.count == 1)
    }

    @Test func initializeAgreesOnAVersion() throws {
        let server = MCPServer(library: try makeLibrary(), version: "1.2")
        for (requested, expected) in [("2025-06-18", "2025-06-18"), ("1999-01-01", MCPServer.protocolVersions[0])] {
            let response = try call(server, ["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": requested]])
            #expect(response["id"] as? String == "a")
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == expected)
            #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "1.2")
            #expect(result["capabilities"] as? [String: Any] != nil)
        }
    }

    @Test func notificationsGetNoResponse() throws {
        let server = MCPServer(library: try makeLibrary())
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func reportsProtocolErrors() throws {
        let server = MCPServer(library: try makeLibrary())
        func code(_ response: [String: Any]) -> Int? { (response["error"] as? [String: Any])?["code"] as? Int }

        let parseError = try #require(server.handle(line: "not json"))
        #expect(code(try #require(try JSONSerialization.jsonObject(with: Data(parseError.utf8)) as? [String: Any])) == -32700)
        #expect(code(try call(server, ["jsonrpc": "2.0", "id": 1, "method": "nope"])) == -32601)
        #expect(code(try call(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "nope"]])) == -32602)
    }

    @Test func listsReadOnlyTools() throws {
        let response = try call(try MCPServer(library: makeLibrary()), ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["list_meetings", "get_transcript", "search_transcripts"])
    }

    @Test func toolsReadMeetings() throws {
        let server = MCPServer(library: try makeLibrary())
        #expect(try callTool(server, "list_meetings", ["limit": 1]).text.contains("2026-11-04 1030 Zoom"))
        #expect(try callTool(server, "search_transcripts", ["query": "ship it"]).text.contains("Speaker 1"))

        let id = "2026/11/2026-11-03 0900 Zoom"
        #expect(try callTool(server, "get_transcript", ["meeting": id]).text.contains("Great, ship it."))
        #expect(try callTool(server, "get_transcript", ["meeting": id, "format": "json"]).text == "{\"version\":1}")
    }

    @Test func toolProblemsComeBackAsToolErrors() throws {
        let server = MCPServer(library: try makeLibrary())
        #expect(try callTool(server, "get_transcript", ["meeting": "../../../etc"]).isError)
        #expect(try callTool(server, "get_transcript", [:]).isError)
        #expect(try callTool(server, "get_transcript", ["meeting": "2026/11/2026-11-04 1030 Zoom", "format": "json"]).isError)
        #expect(try callTool(server, "search_transcripts", ["query": " "]).isError)
    }
}

@Suite struct MeetingEndHookTests {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func install(_ script: String, in dir: URL) throws -> MeetingEndHook {
        let executable = dir.appendingPathComponent("on-meeting-end")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return MeetingEndHook(executable: executable, log: dir.appendingPathComponent("logs/hook.log"))
    }

    @Test func doesNothingWithoutAHook() async throws {
        let dir = try temp()
        let hook = MeetingEndHook(executable: dir.appendingPathComponent("missing"), log: dir.appendingPathComponent("log"))
        #expect(await hook.run(folder: dir, status: .done) == .notInstalled)
    }

    @Test func ignoresFilesThatAreNotExecutable() async throws {
        let dir = try temp()
        let file = dir.appendingPathComponent("on-meeting-end")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let hook = MeetingEndHook(executable: file, log: dir.appendingPathComponent("log"))
        #expect(await hook.run(folder: dir, status: .done) == .notInstalled)
    }

    @Test func passesTheMeetingAndLogsOutput() async throws {
        let dir = try temp()
        let folder = dir.appendingPathComponent("2026-11-04 1030 Zoom", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hook = try install("""
            #!/bin/sh
            echo "cwd:$(basename "$PWD")"
            echo "$1|$TINYMUESLI_MEETING_DIR|$TINYMUESLI_STATUS|$TINYMUESLI_TRANSCRIPT_MD|$TINYMUESLI_TRANSCRIPT_JSON"
            echo oops >&2
            """, in: dir)

        #expect(await hook.run(folder: folder, status: .done) == .exited(0))
        let log = try String(contentsOf: hook.log, encoding: .utf8)
        let path = folder.path
        #expect(log.contains("cwd:\(folder.lastPathComponent)\n"))
        #expect(log.contains("\(path)|\(path)|done|\(path)/transcript.md|\(path)/transcript.json"))
        #expect(log.contains("oops"))
    }

    @Test func reportsAFailingHookAndKeepsEarlierLogs() async throws {
        let dir = try temp()
        let hook = try install("#!/bin/sh\necho second\nexit 3\n", in: dir)
        try FileManager.default.createDirectory(at: hook.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "first\n".write(to: hook.log, atomically: true, encoding: .utf8)

        #expect(await hook.run(folder: dir, status: .failed) == .exited(3))
        let log = try String(contentsOf: hook.log, encoding: .utf8)
        #expect(log.hasPrefix("first\n"))
        #expect(log.contains("second"))
    }

    @Test func reportsAHookThatCannotStart() async throws {
        let dir = try temp()
        let hook = try install("#!/nonexistent/interpreter\n", in: dir)
        guard case .couldNotLaunch = await hook.run(folder: dir, status: .done) else {
            Issue.record("expected couldNotLaunch")
            return
        }
    }
}

@Suite struct AgentPromptTests {
    @Test func containsAnInstallCommandAndConfigForThisBinary() {
        let prompt = AgentPrompt.text(binaryPath: "/Applications/My Apps/tinyMuesli.app/Contents/MacOS/tinyMuesli")
        #expect(prompt.contains("claude mcp add --scope user tinymuesli -- '/Applications/My Apps/tinyMuesli.app/Contents/MacOS/tinyMuesli' mcp"))
        #expect(prompt.contains(#"{"mcpServers":{"tinymuesli":{"args":["mcp"],"command":"/Applications/My Apps/tinyMuesli.app/Contents/MacOS/tinyMuesli"}}}"#))
    }

    @Test func namesEveryToolTheServerOffers() throws {
        let prompt = AgentPrompt.text(binaryPath: "/x")
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let response = try #require(MCPServer(library: MeetingLibrary()).handle(line: line))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let tools = try #require((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in tools.compactMap({ $0["name"] as? String }) {
            #expect(prompt.contains(name))
        }
    }

    @Test func quotesPathsForTheShell() {
        #expect(AgentPrompt.shellQuoted("/a b/it's") == #"'/a b/it'\''s'"#)
    }
}
