import XCTest
@testable import JarvisCore

final class ConversationActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func message(at date: Date, content: String = "Hello", role: String = "user") -> ChatMessage {
        var result = ChatMessage(role: role, content: content)
        result.created = date
        return result
    }

    func testEmptyHistoryHasZeroDaysForEveryRange() {
        for range in [7, 30, 90] {
            let activity = ConversationActivity(messages: [], dayCount: range, now: date("2026-09-10T12:00:00-04:00"), calendar: calendar)
            XCTAssertEqual(activity.days.count, range)
            XCTAssertEqual(activity.total, 0)
            XCTAssertEqual(activity.activeDays, 0)
        }
    }

    func testIncludesTodayAndFirstDayButExcludesOldAndFutureMessages() {
        let now = date("2026-09-10T12:00:00-04:00")
        let messages = [
            message(at: date("2026-09-03T23:59:59-04:00")),
            message(at: date("2026-09-04T00:00:00-04:00")),
            message(at: now, role: "assistant"),
            message(at: now.addingTimeInterval(1))
        ]
        let activity = ConversationActivity(messages: messages, dayCount: 7, now: now, calendar: calendar)
        XCTAssertEqual(activity.total, 2)
        XCTAssertEqual(activity.days.first?.count, 1)
        XCTAssertEqual(activity.days.last?.count, 1)
    }

    func testCalendarDaysRemainCorrectAcrossDaylightSavingTransition() {
        let now = date("2026-03-10T12:00:00-04:00")
        let messages = [
            message(at: date("2026-03-08T01:30:00-05:00")),
            message(at: date("2026-03-08T03:30:00-04:00"), role: "assistant")
        ]
        let activity = ConversationActivity(messages: messages, dayCount: 7, now: now, calendar: calendar)
        XCTAssertEqual(Set(activity.days.map(\.date)).count, 7)
        XCTAssertEqual(activity.activeDays, 1)
        XCTAssertEqual(activity.days.first { calendar.component(.day, from: $0.date) == 8 }?.count, 2)
        XCTAssertTrue(activity.days.allSatisfy { calendar.component(.hour, from: $0.date) == 0 })
    }

    func testRangeSwitchingChangesCountsWithoutInventingHistory() {
        let now = date("2026-09-10T12:00:00-04:00")
        let messages = [0, 15, 60, 100].map { daysAgo in
            message(at: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
        }
        XCTAssertEqual(ConversationActivity(messages: messages, dayCount: 7, now: now, calendar: calendar).total, 1)
        XCTAssertEqual(ConversationActivity(messages: messages, dayCount: 30, now: now, calendar: calendar).total, 2)
        XCTAssertEqual(ConversationActivity(messages: messages, dayCount: 90, now: now, calendar: calendar).total, 3)
    }

    func testStreamingPlaceholderDuplicatesAndNonChatRecordsAreExcluded() {
        let now = date("2026-09-10T12:00:00-04:00")
        let entry = message(at: now)
        let activity = ConversationActivity(messages: [entry, entry, message(at: now, content: "  "), message(at: now, role: "system")], dayCount: 7, now: now, calendar: calendar)
        XCTAssertEqual(activity.total, 1)
    }
}
