import XCTest
@testable import JarvisCore

final class ClaudeBridgeTests: XCTestCase {
    private func call(_ overrides: [String: String] = [:]) -> ToolCall {
        var a = ["prompt": "Goal: explain monads", "model": "claude-opus-5-5", "effort": "high", "project": "", "reason": "Hard reasoning."]
        overrides.forEach { a[$0.key] = $0.value }
        return ToolCall("ask_claude", a)
    }

    func testHandOffAlwaysNeedsTheUser() throws {
        let policy = ActionPolicy(), task = UUID()
        policy.begin(task)
        XCTAssertNotNil(try policy.propose(call(), taskID: task), "a hand-off leaves the Mac and must be approved")
        XCTAssertFalse(ActionPolicy.reads.contains("ask_claude")); XCTAssertFalse(ActionPolicy.instant.contains("ask_claude"))
    }

    func testValidationKeepsTheCardHonest() {
        let policy = ActionPolicy()
        XCTAssertNoThrow(try policy.validate(call()))
        XCTAssertNoThrow(try policy.validate(call(["project": "Weather App", "reason": ""])))
        XCTAssertThrowsError(try policy.validate(call(["model": "gpt-9"])))
        XCTAssertThrowsError(try policy.validate(call(["effort": "extreme"])))
        XCTAssertThrowsError(try policy.validate(call(["prompt": "   "])))
        XCTAssertThrowsError(try policy.validate(call(["prompt": String(repeating: "x", count: 48_001)])))
        for bad in ["../escape", "/etc", ".hidden", "a/b", String(repeating: "p", count: 61)] {
            XCTAssertThrowsError(try policy.validate(call(["project": bad])), bad)
        }
    }

    func testAnswerRunsGetNoFileOrShellTools() {
        let args = ClaudeCLI.arguments(for: ClaudeHandoff(prompt: "Why?", model: "claude-sonnet-5", effort: "medium"))
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "Why?"])
        XCTAssertTrue(args.contains("stream-json")); XCTAssertTrue(args.contains("--verbose"))
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "claude-sonnet-5")
        XCTAssertEqual(args[args.firstIndex(of: "--effort")! + 1], "medium")
        let denied = args.firstIndex(of: "--disallowedTools")!
        XCTAssertEqual(Array(args[(denied + 1)...(denied + 4)]), ["Bash", "Edit", "Write", "NotebookEdit"])
        XCTAssertFalse(args.contains("--permission-mode")); XCTAssertFalse(args.contains("--resume"))
    }

    func testBuildRunsAreSandboxedToTheProject() throws {
        let args = ClaudeCLI.arguments(for: ClaudeHandoff(prompt: "Build it", model: "claude-opus-5-5", effort: "xhigh",
                                                          projectPath: "/tmp/p", resumeSession: "abc",
                                                          pluginDirectories: ["/x/plugin"], mcpConfig: "/x/mcp.json"))
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
        let settings = args[args.firstIndex(of: "--settings")! + 1]
        let sandbox = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])?["sandbox"] as? [String: Bool])
        XCTAssertEqual(sandbox["enabled"], true); XCTAssertEqual(sandbox["allowUnsandboxedCommands"], false)
        XCTAssertEqual(args[args.firstIndex(of: "--resume")! + 1], "abc")
        XCTAssertEqual(args[args.firstIndex(of: "--plugin-dir")! + 1], "/x/plugin")
        XCTAssertEqual(args[args.firstIndex(of: "--mcp-config")! + 1], "/x/mcp.json")
        XCTAssertFalse(args.contains("--disallowedTools"))
    }

    /// Shapes recorded from Claude Code 2.1.280's stream-json output.
    func testStreamParsing() {
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-haiku-4-5-20251001","cwd":"/x"}"#),
                       [.started(session: "s1", model: "claude-haiku-4-5-20251001")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"system","subtype":"commands_changed","session_id":"s1"}"#), [])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"bridge ok"}]}}"#),
                       [.text("bridge ok")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/p/src/index.html"}},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}"#),
                       [.activity("Writing index.html"), .activity("Running `npm test`")])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1","duration_ms":1866,"total_cost_usd":0.06}"#),
                       [.finished(result: "done", session: "s1", isError: false, seconds: 1.866, cost: 0.06)])
        XCTAssertEqual(ClaudeStream.parse(#"{"type":"result","subtype":"error_max_turns","session_id":"s2","duration_ms":10}"#),
                       [.finished(result: "", session: "s2", isError: true, seconds: 0.01, cost: nil)])
        XCTAssertEqual(ClaudeStream.parse("not json"), [])
    }

    func testProjectsLiveInTheirOwnFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeProjectStore(file: root.appendingPathComponent("projects.json"), buildsRoot: root.appendingPathComponent("Builds"))
        let made = try store.open("Weather App")
        XCTAssertEqual(made.path, root.appendingPathComponent("Builds/Weather App").path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try store.open("weather app").path, made.path, "names match case-insensitively instead of making a twin")
        store.remember(session: "sess-1", for: "WEATHER APP")
        XCTAssertEqual(store.find("Weather App")?.sessionID, "sess-1")
        let existing = root.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertEqual(try store.add(name: "Shotcode", folder: existing).path, existing.standardizedFileURL.path)
        XCTAssertThrowsError(try store.add(name: "shotcode", folder: existing))
        XCTAssertThrowsError(try store.open("../../etc"))
        store.remove("Weather App")
        XCTAssertNil(store.find("Weather App"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path), "forgetting a project never deletes its files")
    }

    func testSuggestionsScaleWithTheTask() {
        XCTAssertEqual(ClaudeCatalog.suggestion(prompt: "x", building: true).model, "claude-opus-5-5")
        XCTAssertEqual(ClaudeCatalog.suggestion(prompt: "What year is it?", building: false).model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(ClaudeCatalog.suggestion(prompt: "Design the architecture for a sync engine", building: false).effort, "high")
    }
}
