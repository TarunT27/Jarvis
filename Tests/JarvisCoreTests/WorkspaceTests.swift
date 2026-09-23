import XCTest
import CryptoKit
@testable import JarvisCore

final class WorkspaceTests:XCTestCase {
    private func withVault(_ operation:(Vault,URL,SymmetricKey)throws->Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url=directory.appendingPathComponent("vault.enc"),key=SymmetricKey(size:.bits256)
        defer { try? FileManager.default.removeItem(at:directory) }
        let vault=try Vault(url:url,key:key)
        try operation(vault,url,key)
    }
    func testWorkspaceRoundTripUpdateEncryptionAndIndexDeletion() throws {
        try withVault { vault,url,key in
            var note=WorkspaceItem(kind:.note,title:"Local notes",body:"private narwhal content")
            try WorkspaceStore.save(note,in:vault)
            XCTAssertNil(try Data(contentsOf:url).range(of:Data(note.body.utf8)))
            let reopened=try Vault(url:url,key:key)
            XCTAssertEqual(try WorkspaceStore.list(reopened).first?.body,note.body)
            note.body="revised walrus content";try WorkspaceStore.save(note,in:vault)
            XCTAssertEqual(try WorkspaceStore.list(vault).count,1)
            XCTAssertTrue(try vault.rows(query:"narwhal").isEmpty)
            XCTAssertEqual(try vault.rows(query:"walrus").count,1)
            try WorkspaceStore.delete(note.id,from:vault)
            XCTAssertTrue(try vault.rows(query:"walrus").isEmpty)
            XCTAssertTrue(try WorkspaceStore.list(vault).isEmpty)
        }
    }
    func testWorkspaceCannotOverwriteOrDeleteCredentialNamespace() throws {
        try withVault { vault,_,_ in
            let id=UUID()
            try vault.put(kind:"credential",body:"secret",id:id.uuidString)
            try WorkspaceStore.save(WorkspaceItem(id:id,kind:.prompt,title:"Prompt",body:"hello"),in:vault)
            try WorkspaceStore.delete(id,from:vault)
            XCTAssertEqual(try vault.rows(kind:"credential").first?["body"],"secret")
            XCTAssertThrowsError(try WorkspaceStore.delete(id,from:vault))
        }
    }
    func testWorkspaceRejectsInvalidKindsAndOversizedInput() throws {
        XCTAssertThrowsError(try WorkspaceItem(kind:.note,title:" ",body:"").validated())
        XCTAssertThrowsError(try WorkspaceItem(kind:.note,title:"OK",body:String(repeating:"ా",count:12_000)).validated())
        XCTAssertThrowsError(try WorkspaceItem(kind:.note,title:"OK",body:"null\0").validated())
        let item=WorkspaceItem(kind:.note,title:"OK",body:"data")
        let encoded=String(decoding:try JSONEncoder().encode(item),as:UTF8.self).replacingOccurrences(of:"\"note\"",with:"\"credential\"")
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceItem.self,from:Data(encoded.utf8)))
    }
    func testTemplateExpandsOnlyExplicitLocalVariables() {
        let item=WorkspaceItem(kind:.prompt,title:"Test",body:"{{date}} {{timezone}} {{clipboard}} $(whoami) {{file:/etc/passwd}}")
        let result=item.expanded(now:Date(timeIntervalSince1970:0),timeZone:TimeZone(secondsFromGMT:0)!)
        XCTAssertTrue(result.hasPrefix("1970-01-01"))
        XCTAssertTrue(result.contains("{{clipboard}} $(whoami) {{file:/etc/passwd}}"))
    }
    func testPrivacySurvivesVaultReopenAndNewConversationStaysClean() throws {
        try withVault { vault,url,key in
            let chat=UUID()
            XCTAssertFalse(try ConversationPrivacy.isPrivate(chat,in:vault))
            try ConversationPrivacy.mark(chat,in:vault)
            let reopened=try Vault(url:url,key:key)
            XCTAssertTrue(try ConversationPrivacy.isPrivate(chat,in:reopened))
            XCTAssertFalse(try ConversationPrivacy.isPrivate(UUID(),in:reopened))
        }
    }
    func testGenerationLimitsRejectResourceEscape() {
        var options=GenerationOptions()
        XCTAssertNoThrow(try options.validated())
        options.maximumTokens=100_000;XCTAssertThrowsError(try options.validated())
        options.maximumTokens=1024;options.temperature = .nan;XCTAssertThrowsError(try options.validated())
        options.temperature = -1;XCTAssertThrowsError(try options.validated())
    }
    func testStatisticsUseNanosecondsAndMissingIsNotZero() {
        let stats=GenerationStatistics(model:"local",response:["eval_count":60,"eval_duration":2_000_000_000.0,"total_duration":3_000_000_000.0])
        XCTAssertEqual(stats.tokensPerSecond,30);XCTAssertEqual(stats.totalSeconds,3)
        XCTAssertNil(stats.inputTokens)
        XCTAssertNil(GenerationStatistics(model:"local",response:["eval_count":60,"eval_duration":0]).tokensPerSecond)
        XCTAssertNil(GenerationStatistics(model:"local",response:[:]).outputTokens)
    }
    func testMarkdownKeepsCodeInertAndHandlesStreamingFences() {
        XCTAssertEqual(MessageMarkdown.blocks("# Title\nHello **world**\n```python\nprint('hello')\n```"),[
            .heading(level:1,content:"Title"),.text("Hello **world**"),.code(language:"python",content:"print('hello')")])
        XCTAssertEqual(MessageMarkdown.blocks("~~~js\n<script>no execution</script>"),[.code(language:"js",content:"<script>no execution</script>")])
        XCTAssertEqual(MessageMarkdown.blocks("````text\n```\n````"),[.code(language:"text",content:"```")])
    }
    func testLegacyChatsDecodeAndExportDoesNotCarryToolAuthority() throws {
        let old=Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"role\":\"user\",\"content\":\"Hello\",\"created\":0}".utf8)
        let message=try JSONDecoder().decode(ChatMessage.self,from:old)
        XCTAssertNil(message.privateContext);XCTAssertNil(message.statistics)
        let export=ConversationExport(title:"Example",messages:[message])
        XCTAssertTrue(export.markdown.contains("## You\n\nHello"))
        let json=String(decoding:try JSONEncoder().encode(export),as:UTF8.self)
        XCTAssertFalse(json.contains("taskID"));XCTAssertFalse(json.contains("proposal"))
    }

    func testPlainTextDropsMarkupAndCodeForSpeech() {
        let spoken=MessageMarkdown.plainText("## Done\nSet **volume** to `20`. See [Apple](https://apple.com).\n- one\n2. two\n```swift\nprint(1)\n```")
        XCTAssertEqual(spoken,"Done\nSet volume to 20. See Apple.\none\ntwo")
    }
}
