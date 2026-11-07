import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct CodexConfigTests {
    @Test func addsTheServerToAnEmptyConfig() {
        let config = CodexConfig.adding(binaryPath: "/Apps/tinyMuesli", to: "")
        #expect(config == """
            [mcp_servers.tinymuesli]
            command = "/Apps/tinyMuesli"
            args = ["mcp"]

            """)
        #expect(CodexConfig.contains(config))
    }

    @Test func keepsEverythingElseAndReplacesAnOldEntry() {
        let existing = """
            model = "gpt-5"

            [mcp_servers.tinymuesli]
            command = "/old/path"
            args = ["mcp"]

            [mcp_servers.tinymuesli.env]
            A = "1"

            [mcp_servers.other]
            command = "other"

            """
        let config = CodexConfig.adding(binaryPath: "/new/path \"x\"", to: existing)
        #expect(config == """
            model = "gpt-5"

            [mcp_servers.other]
            command = "other"

            [mcp_servers.tinymuesli]
            command = "/new/path \\"x\\""
            args = ["mcp"]

            """)
        #expect(!config.contains("/old/path"))
    }

    @Test func installsIntoAFileAndReportsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = dir.appending(path: ".codex/config.toml")
        #expect(!CodexConfig.isInstalled(at: url))
        try CodexConfig.install(binaryPath: "/x", at: url)
        try CodexConfig.install(binaryPath: "/x", at: url)
        #expect(CodexConfig.isInstalled(at: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "[mcp_servers.tinymuesli]").count == 2)
        try? FileManager.default.removeItem(at: dir)
    }
}
