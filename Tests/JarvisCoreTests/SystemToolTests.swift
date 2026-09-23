import XCTest
@testable import JarvisCore

final class SystemToolTests: XCTestCase {
    private func valid(_ name: String, _ arguments: [String: String] = [:]) -> Bool {
        (try? ActionPolicy().validate(ToolCall(name, arguments))) != nil
    }

    func testCatalogClassifiesEveryToolExactlyOnce() {
        for name in SystemToolCatalog.all {
            XCTAssertNotNil(ActionPolicy.allowed[name], "\(name) missing from the enforced policy")
            XCTAssertNotNil(SystemToolCatalog.descriptions[name], "\(name) needs a description")
            let classes = [SystemToolCatalog.reads, SystemToolCatalog.instant, SystemToolCatalog.approved].filter { $0.contains(name) }
            XCTAssertEqual(classes.count, 1, "\(name) must be exactly one of read, instant, approved")
        }
        XCTAssertTrue(ActionPolicy.reads.isDisjoint(with: ActionPolicy.instant))
        for name in SystemToolCatalog.approved {
            XCTAssertFalse(ActionPolicy.reads.contains(name)); XCTAssertFalse(ActionPolicy.instant.contains(name))
        }
    }

    func testApprovalIsRequiredOnlyWhereItShouldBe() throws {
        let policy = ActionPolicy(), task = UUID()
        policy.begin(task)
        XCTAssertNil(try policy.propose(ToolCall("set_volume", ["level": "30"]), taskID: task))
        XCTAssertNil(try policy.propose(ToolCall("system_status"), taskID: task))
        XCTAssertNotNil(try policy.propose(ToolCall("lock_screen"), taskID: task))
        XCTAssertNotNil(try policy.propose(ToolCall("clipboard_read"), taskID: task))
        XCTAssertNotNil(try policy.propose(ToolCall("open_url", ["url": "https://example.com"]), taskID: task))
    }

    func testLevelsAndTimersAreStrict() {
        XCTAssertTrue(valid("set_volume", ["level": "0"])); XCTAssertTrue(valid("set_volume", ["level": "100"]))
        XCTAssertTrue(valid("set_volume", ["level": "mute"])); XCTAssertTrue(valid("set_volume", ["level": "Unmute"]))
        for bad in ["101", "-1", "50.5", "50%", "fifty", "0050", ""] { XCTAssertFalse(valid("set_volume", ["level": bad]), bad) }
        XCTAssertFalse(valid("set_brightness", ["level": "mute"]))
        XCTAssertTrue(valid("set_dark_mode", ["enabled": "true"])); XCTAssertFalse(valid("set_dark_mode", ["enabled": "yes"]))
        XCTAssertTrue(valid("media_control", ["action": "next"])); XCTAssertFalse(valid("media_control", ["action": "stop"]))
        XCTAssertTrue(valid("set_timer", ["seconds": "300", "label": ""]))
        XCTAssertTrue(valid("set_timer", ["seconds": "86400", "label": "Tea"]))
        for bad in ["0", "86401", "5m", "1e3", " 30"] { XCTAssertFalse(valid("set_timer", ["seconds": bad, "label": ""]), bad) }
        XCTAssertFalse(valid("set_timer", ["seconds": "60", "label": "a\nb"]))
        XCTAssertFalse(valid("set_timer", ["seconds": "60"]), "label is optional in value, not in shape")
    }

    func testURLsMustBePlainWebAddresses() {
        XCTAssertTrue(valid("open_url", ["url": "https://www.apple.com/mac/"]))
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "https://user:pw@example.com",
                    "example.com", "https://", "x-apple.systempreferences:com.apple.preference.security"] {
            XCTAssertFalse(valid("open_url", ["url": bad]), bad)
        }
    }

    func testQuitRefusesTheSessionAndJarvis() {
        XCTAssertTrue(valid("quit_app", ["bundle_id": "com.apple.TextEdit"]))
        for bad in ["com.apple.finder", "com.apple.loginwindow", "local.jarvis.mac", "local.jarvis.mac.broker", "com.apple.TextEdit; rm"] {
            XCTAssertFalse(valid("quit_app", ["bundle_id": bad]), bad)
        }
    }

    func testOpenFileOpensDocumentsNeverPrograms() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Documents/Tool.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".secret"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let write = { (path: String) in try Data("x".utf8).write(to: home.appendingPathComponent(path)) }
        try write("Documents/report.pdf"); try write("Documents/run.command"); try write("Documents/tool")
        try write("Library/prefs.plist"); try write(".secret/key.txt"); try write("Documents/Tool.app/Contents/inner.txt")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Documents/tool").path)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Documents/escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        let open = { (path: String) in try SystemToolPolicy.openablePath(home.path + "/" + path, home: home) }
        XCTAssertEqual(try open("Documents/report.pdf").lastPathComponent, "report.pdf")
        XCTAssertNoThrow(try open("Documents"))
        for bad in ["Documents/run.command", "Documents/tool", "Documents/Tool.app", "Documents/Tool.app/Contents/inner.txt",
                    "Library/prefs.plist", ".secret/key.txt", "Documents/escape/hosts", "Documents/missing.pdf", "Documents/../../etc"] {
            XCTAssertThrowsError(try open(bad), bad)
        }
        XCTAssertThrowsError(try SystemToolPolicy.openablePath("relative/report.pdf", home: home))
    }

    @MainActor func testStatusReadsWithoutChangingAnything() {
        let status = SystemController().status()
        XCTAssertNotNil(status["macos"]); XCTAssertNotNil(status["memory_gb"]); XCTAssertNotNil(status["dark_mode"])
    }
}
