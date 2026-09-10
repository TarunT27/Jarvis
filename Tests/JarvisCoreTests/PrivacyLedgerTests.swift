import XCTest
@testable import JarvisCore

/// The control that stops private content reaching a web search query.
final class PrivacyLedgerTests: XCTestCase {
    func testTaintSurvivesTheEndOfTheTaskThatCausedIt() {
        let ledger = PrivacyLedger()
        let chat = UUID(), first = UUID(), second = UUID()

        ledger.begin(task: first, conversation: chat)
        XCTAssertTrue(ledger.webAllowed(task: first))
        ledger.markPrivate(task: first)          // e.g. gmail_read
        XCTAssertFalse(ledger.webAllowed(task: first))
        ledger.endTask(first)                    // the user's message completes

        // The next message in the same conversation must still be refused. This is the
        // regression: per-task state made turn two clean and let content leak into search.
        ledger.begin(task: second, conversation: chat)
        XCTAssertFalse(ledger.webAllowed(task: second))
        XCTAssertFalse(ledger.webAllowed(conversation: chat))
    }

    func testANewConversationStartsClean() {
        let ledger = PrivacyLedger()
        let old = UUID(), fresh = UUID(), task = UUID(), later = UUID()
        ledger.begin(task: task, conversation: old)
        ledger.markPrivate(task: task)
        XCTAssertFalse(ledger.webAllowed(conversation: old))

        ledger.begin(task: later, conversation: fresh)
        XCTAssertTrue(ledger.webAllowed(task: later), "New Conversation must restore web search")
    }

    func testAttachedScreenContentTaintsImmediately() {
        let ledger = PrivacyLedger()
        let chat = UUID(), task = UUID()
        // The broker never sees the screenshot, so the app declares it at begin.
        ledger.begin(task: task, conversation: chat, carriesPrivateContent: true)
        XCTAssertFalse(ledger.webAllowed(task: task))
    }

    func testUnknownTaskIsRefusedRatherThanAllowed() {
        // A task the ledger never saw must fail closed.
        XCTAssertFalse(PrivacyLedger().webAllowed(task: UUID()))
    }

    func testEvictionForgetsOldestConversationsAndKeepsRecentTaint() {
        let ledger = PrivacyLedger(capacity: 3)
        let recent = UUID(), recentTask = UUID()
        ledger.begin(task: recentTask, conversation: recent)
        ledger.markPrivate(task: recentTask)

        // Push the tainted conversation out of a 3-slot ledger.
        for _ in 0..<3 { ledger.begin(task: UUID(), conversation: UUID()) }
        XCTAssertTrue(ledger.webAllowed(conversation: recent), "evicted conversation should be forgotten")

        // A conversation still inside the window keeps its taint.
        let kept = UUID(), keptTask = UUID()
        ledger.begin(task: keptTask, conversation: kept)
        ledger.markPrivate(task: keptTask)
        ledger.begin(task: UUID(), conversation: UUID())
        XCTAssertFalse(ledger.webAllowed(conversation: kept))
    }

    func testCancelDoesNotLaunderTaint() {
        let ledger = PrivacyLedger()
        let chat = UUID(), task = UUID(), afterStop = UUID()
        ledger.begin(task: task, conversation: chat)
        ledger.markPrivate(task: task)
        ledger.forgetTasks()                     // the Stop button

        ledger.begin(task: afterStop, conversation: chat)
        XCTAssertFalse(ledger.webAllowed(task: afterStop), "Stop must not clear the conversation's taint")
    }
}
