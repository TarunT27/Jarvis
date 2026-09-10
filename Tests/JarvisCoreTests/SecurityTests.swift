import XCTest
import CryptoKit
@testable import JarvisCore
final class SecurityTests: XCTestCase {
    func testApprovalsBoundToExactArgumentsAndSingleUse() throws {
        let p = ActionPolicy(); let task = UUID(); p.begin(task)
        let original = try XCTUnwrap(p.propose(ToolCall("send_email",["to":"a@example.com","subject":"Hello","body":"Draft"]),taskID:task))
        var changed = original; changed.call.arguments["to"] = "attacker@example.com"
        XCTAssertThrowsError(try p.consume(changed)); XCTAssertThrowsError(try p.consume(original))
        let next = try XCTUnwrap(p.propose(original.call,taskID:task))
        XCTAssertEqual(try p.consume(next),original.call); XCTAssertThrowsError(try p.consume(next))
    }
    func testCancellationExpiryAndUnsupportedTools() throws {
        let p=ActionPolicy(); let task=UUID(); p.begin(task)
        let a=try XCTUnwrap(p.propose(ToolCall("save_memory",["text":"test"]),taskID:task))
        XCTAssertThrowsError(try p.consume(a,now:Date().addingTimeInterval(121)))
        XCTAssertThrowsError(try p.propose(ToolCall("shell",["command":"echo no"]),taskID:task))
        p.end(task); XCTAssertThrowsError(try p.propose(ToolCall("web_search",["query":"test"]),taskID:task))
    }
    func testHeaderInjectionRejected() {
        XCTAssertThrowsError(try ActionPolicy().validate(ToolCall("send_email",["to":"a@example.com\r\nBcc: b@example.com","subject":"Hello","body":"x"])))
    }
    func testSymlinkEscapeAndSiblingPrefix() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:URL(fileURLWithPath:"/etc"))
        XCTAssertThrowsError(try PathPolicy.resolve(root.appendingPathComponent("escape/passwd").path,roots:[root]))
        XCTAssertThrowsError(try PathPolicy.resolve(root.path+"-other/file",roots:[root],mustExist:false))
    }
    func testVaultEncryptionSearchDeletionAndWrongKey() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Retain encrypted test artifact until the suite completes.
        let url=folder.appendingPathComponent("vault.enc"), key=SymmetricKey(size:.bits256)
        var vault: Vault? = try Vault(url:url,key:key)
        try vault!.put(kind:"memory",body:"private elephant secret",id:"one")
        XCTAssertEqual(try vault!.rows(query:"elephant").count,1)
        let raw=try Data(contentsOf:url)
        XCTAssertNil(raw.range(of:Data("private elephant secret".utf8)))
        vault=nil
        XCTAssertThrowsError(try Vault(url:url,key:SymmetricKey(size:.bits256)))
        let reopened=try Vault(url:url,key:key)
        XCTAssertEqual(try reopened.rows(query:"elephant").count,1)
        try reopened.delete(id:"one"); XCTAssertTrue(try reopened.rows(query:"elephant").isEmpty)
    }
    func testCalendarRejectsIntervalSmuggledIntoASingleDateField() throws {
        // The everyday model was observed emitting "<start>/<end>" into `start`.
        // The broker must refuse it rather than acting on a half-understood range.
        let p = ActionPolicy()
        let interval = ToolCall("calendar_list",["start":"2026-09-11T12:00:00-04:00/2026-09-11T18:00:00-04:00",
                                                "end":"2026-09-11T18:00:00-04:00"])
        XCTAssertThrowsError(try p.validate(interval))
        XCTAssertNoThrow(try p.validate(ToolCall("calendar_list",["start":"2026-09-11T12:00:00-04:00",
                                                                 "end":"2026-09-11T18:00:00-04:00"])))
        // A naked local time with no offset is ambiguous and must also be refused.
        XCTAssertThrowsError(try p.validate(ToolCall("calendar_list",["start":"2026-09-11T12:00:00",
                                                                     "end":"2026-09-11T18:00:00"])))
    }
    func testCalendarRejectsInvertedRangeAndUnknownTimezone() {
        let p = ActionPolicy()
        XCTAssertThrowsError(try p.validate(ToolCall("calendar_create",
            ["title":"Review","start":"2026-09-11T18:00:00-04:00","end":"2026-09-11T12:00:00-04:00",
             "timezone":"America/New_York","attendees":""])))
        XCTAssertThrowsError(try p.validate(ToolCall("calendar_create",
            ["title":"Review","start":"2026-09-11T12:00:00-04:00","end":"2026-09-11T13:00:00-04:00",
             "timezone":"Mars/Olympus","attendees":""])))
    }
    func testToolCatalogMatchesEnforcedPolicy() throws {
        // The benchmark harness and the model both read this catalog; if it ever drifts
        // from ActionPolicy.allowed the model would be offered a call the broker rejects.
        XCTAssertEqual(ToolCatalog.definitions.count, ActionPolicy.allowed.count)
        for definition in ToolCatalog.definitions {
            let function = try XCTUnwrap(definition["function"] as? [String:Any])
            let name = try XCTUnwrap(function["name"] as? String)
            let parameters = try XCTUnwrap(function["parameters"] as? [String:Any])
            let required = Set(try XCTUnwrap(parameters["required"] as? [String]))
            XCTAssertEqual(required, try XCTUnwrap(ActionPolicy.allowed[name]), "catalog drift in \(name)")
            let description = function["description"] as? String ?? ""
            XCTAssertFalse(description.isEmpty, "\(name) needs a description the model can act on")
        }
        // Every consequential tool must require approval rather than running inline.
        for name in ["send_email","move_file","trash_file","create_reminder","calendar_create","save_memory"] {
            XCTAssertFalse(ActionPolicy.reads.contains(name), "\(name) must not be a read")
        }
    }
    func testApprovalCannotCrossTasks() throws {
        let p = ActionPolicy(); let mine = UUID(); let other = UUID()
        p.begin(mine); p.begin(other)
        var stolen = try XCTUnwrap(p.propose(ToolCall("trash_file",["path":"/tmp/a"]),taskID:mine))
        stolen.taskID = other
        XCTAssertThrowsError(try p.consume(stolen))
    }
    func testCredentialsLiveEncryptedInTheVaultNotTheKeychain() throws {
        // The broker is an XPC service and cannot create Keychain items, so Google tokens
        // and the search key are kept in the vault. They must never appear in plaintext.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("vault.enc"), key = SymmetricKey(size: .bits256)
        var vault: Vault? = try Vault(url: url, key: key)
        let token = Data("ya29.super-secret-refresh-token".utf8)
        try vault!.setCredential(token, for: "google-token")
        XCTAssertEqual(try vault!.credential("google-token"), token)
        XCTAssertNil(try vault!.credential("brave-key"))

        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: token))
        XCTAssertNil(raw.range(of: Data("google-token".utf8)))

        // Survives a reopen with the same key, and clears on request.
        vault = nil
        let reopened = try Vault(url: url, key: key)
        XCTAssertEqual(try reopened.credential("google-token"), token)
        try reopened.setCredential(nil, for: "google-token")
        XCTAssertNil(try reopened.credential("google-token"))
        try? FileManager.default.removeItem(at: folder)
    }
}
