import Foundation

/// Read-only projection of the messages already available to the interface.
/// Does not load additional history, persist analytics, or change retention.
public struct ConversationActivity: Sendable {
    public struct Day: Identifiable, Equatable, Sendable {
        public let date: Date
        public let count: Int
        public var id: Date { date }
    }

    public let days: [Day]
    public var total: Int { days.reduce(0) { $0 + $1.count } }
    public var activeDays: Int { days.filter { $0.count > 0 }.count }

    public init(messages: [ChatMessage], dayCount: Int, now: Date = Date(), calendar: Calendar = .current) {
        let count = min(90, max(1, dayCount))
        let today = calendar.startOfDay(for: now)
        let dates = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - count + 1, to: today) }
        guard let start = dates.first else { days = []; return }
        var seen = Set<UUID>()
        var totals: [Date: Int] = [:]
        for message in messages where message.created >= start && message.created <= now {
            guard ["user", "assistant"].contains(message.role),
                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(message.id).inserted else { continue }
            totals[calendar.startOfDay(for: message.created), default: 0] += 1
        }
        days = dates.map { Day(date: $0, count: totals[$0, default: 0]) }
    }
}
