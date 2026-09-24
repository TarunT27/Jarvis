import XCTest
@testable import JarvisCore

final class ExtensionsTests: XCTestCase {
    private var root: URL!
    private var library: ExtensionLibrary!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-ext-test-\(UUID().uuidString)")
        library = ExtensionLibrary(paths: ExtensionPaths(root: root))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testFrontMatterReadsTheFieldsClaudeUses() {
        let plain = ExtensionFormat.frontMatter("---\nname: pdf-tools\ndescription: \"Fill PDF forms: when asked\"\n---\n# Body")
        XCTAssertEqual(plain["name"], "pdf-tools"); XCTAssertEqual(plain["description"], "Fill PDF forms: when asked")
        let folded = ExtensionFormat.frontMatter("---\nname: x\ndescription: >\n  Use for\n  release notes.\nlicense: MIT\n---\n")
        XCTAssertEqual(folded["description"], "Use for release notes."); XCTAssertEqual(folded["license"], "MIT")
        XCTAssertTrue(ExtensionFormat.frontMatter("# no front matter").isEmpty)
    }

    func testSkillsCreateImportToggleAndTravelToClaude() throws {
        let made = try library.createSkill(name: "Release Notes", description: "Write release notes from commits", instructions: "Group by feature.")
        XCTAssertEqual(made.name, "release-notes")
        XCTAssertThrowsError(try library.createSkill(name: "release-notes", description: "dup", instructions: ""))
        XCTAssertThrowsError(try library.createSkill(name: "../", description: "nothing usable left after slugging", instructions: ""))

        let source = root.appendingPathComponent("incoming/apple-ui")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: apple-ui\ndescription: Make it feel native\n---\nUse SF Pro.".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try library.importSkills(from: root.appendingPathComponent("incoming")), ["apple-ui"])
        XCTAssertEqual(Set(library.enabledSkills().map(\.id)), ["apple-ui", "release-notes"])

        var state = library.state(); state.disabledSkills = ["apple-ui"]; try library.save(state)
        XCTAssertEqual(library.enabledSkills().map(\.id), ["release-notes"])
        let dirs = library.claudePluginDirectories()
        XCTAssertEqual(dirs.count, 1)
        let bundled = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: dirs[0]).appendingPathComponent("skills").path)
        XCTAssertEqual(bundled, ["release-notes"], "switched-off skills stay home")
        state.shareWithClaude = false; try library.save(state)
        XCTAssertTrue(library.claudePluginDirectories().isEmpty)
    }

    func testServersParseClaudeDesktopConfigAndReject() throws {
        let added = try library.addServers(json: #"{"mcpServers":{"files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"]},"remote tools":{"type":"http","url":"https://mcp.example.com/mcp","headers":{"Authorization":"Bearer x"}}}}"#)
        XCTAssertEqual(Set(added), ["files", "remote_tools"])
        let servers = try library.userServers()
        XCTAssertEqual(servers.first { $0.id == "files" }?.transport, .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], env: [:]))
        XCTAssertThrowsError(try library.addServers(json: #"{"mcpServers":{"bad":{"url":"file:///etc/passwd"}}}"#))
        XCTAssertThrowsError(try library.addServers(json: "[]"))
        try library.removeServer("files")
        XCTAssertEqual(try library.userServers().map(\.id), ["remote_tools"])
        let config = try XCTUnwrap(library.claudeMCPConfig())
        let perms = try FileManager.default.attributesOfItem(atPath: config)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "headers can hold tokens")
    }

    func testPluginsInstallFromClaudeCodeLayout() throws {
        let source = root.appendingPathComponent("download/wrapper")
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills/lint"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("commands"), withIntermediateDirectories: true)
        try #"{"name":"Dev Kit","version":"1.2.0","description":"Tools for devs"}"#.write(to: source.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try "---\nname: lint\ndescription: Lint code\n---\n".write(to: source.appendingPathComponent("skills/lint/SKILL.md"), atomically: true, encoding: .utf8)
        try "Review".write(to: source.appendingPathComponent("commands/review.md"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"git":{"command":"uvx","args":["mcp-server-git"]}}}"#.write(to: source.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let plugin = try library.installPlugin(from: root.appendingPathComponent("download"))   // one wrapping folder
        XCTAssertEqual(plugin.name, "dev-kit"); XCTAssertEqual(plugin.version, "1.2.0")
        XCTAssertEqual([plugin.skillCount, plugin.serverCount, plugin.commandCount], [1, 1, 1])
        XCTAssertTrue(library.skills().contains { $0.id == "dev-kit:lint" && $0.plugin == "dev-kit" })
        XCTAssertEqual(library.enabledServers().map(\.id), ["dev-kit__git"])
        XCTAssertThrowsError(try library.removeSkill(library.skills().first { $0.plugin != nil }!))

        var state = library.state(); state.disabledPlugins = ["dev-kit"]; try library.save(state)
        XCTAssertFalse(library.skills().contains { $0.plugin == "dev-kit" })
        XCTAssertTrue(library.enabledServers().isEmpty, "a switched-off plugin takes its servers with it")
        XCTAssertThrowsError(try library.installPlugin(from: root.appendingPathComponent("download/wrapper/skills")))
    }

    func testMCPPolicyNeedsAKnownToolAndOneJSONObject() throws {
        let policy = ActionPolicy(), task = UUID()
        policy.begin(task)
        let call = ToolCall("mcp__files__read_file", ["_json": #"{"path":"/tmp/a"}"#])
        XCTAssertThrowsError(try policy.propose(call, taskID: task), "unknown until a running server offers it")
        policy.dynamicTools = ["mcp__files__read_file": false]
        XCTAssertNotNil(try policy.propose(call, taskID: task), "asks every time by default")
        policy.dynamicTools = ["mcp__files__read_file": true]
        XCTAssertNil(try policy.propose(call, taskID: task), "always-allowed runs directly")
        XCTAssertThrowsError(try policy.validate(ToolCall("mcp__files__read_file", ["_json": "[1,2]"])))
        XCTAssertThrowsError(try policy.validate(ToolCall("mcp__files__read_file", ["_json": "{}", "extra": "x"])))
        XCTAssertTrue(ActionPolicy.reads.contains("use_skill"))
    }

    /// A real stdio round trip against a minimal MCP server.
    func testClientTalksToAStdioServer() async throws {
        let script = root.appendingPathComponent("echo_mcp.py")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"""
        import json, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize": r = {"protocolVersion": m["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "echo", "version": "1"}}
            elif m["method"] == "tools/list": r = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
            elif m["method"] == "tools/call": r = {"content": [{"type": "text", "text": "echo: " + m["params"]["arguments"]["text"]}]}
            else: r = None
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r} if r is not None else {"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "no such method"}}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let connection = MCPConnection(config: MCPServerConfig(id: "echo", transport: .stdio(command: "/usr/bin/python3", args: [script.path], env: [:]), plugin: nil))
        let tools = try await connection.start()
        XCTAssertEqual(tools.map(\.qualified), ["mcp__echo__echo"])
        XCTAssertEqual((tools[0].definition["function"] as? [String: Any])?["name"] as? String, "mcp__echo__echo")
        let reply = try await connection.call(tool: "echo", arguments: ["text": "hi"])
        XCTAssertEqual(reply, "echo: hi")
        await connection.stop()
    }

    func testResultsAndHTTPRepliesAreReadable() {
        XCTAssertEqual(MCPProtocol.text(of: ["content": [["type": "text", "text": "a"], ["type": "image", "mimeType": "image/png"]]]), "a\n[image image/png]")
        XCTAssertEqual(MCPProtocol.text(of: ["isError": true, "content": [["type": "text", "text": "boom"]]]), "The tool reported an error: boom")
        let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}\n\n".utf8)
        XCTAssertEqual(MCPProtocol.response(in: sse, contentType: "text/event-stream", id: 3)?["id"] as? Int, 3)
        XCTAssertNil(MCPProtocol.response(in: sse, contentType: "text/event-stream", id: 4))
    }
}
