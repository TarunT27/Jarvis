import Foundation

/// Tracks which conversations have seen private content, so web search can be refused
/// for the rest of that conversation.
///
/// The scope matters. An earlier version tracked this per task, where a task is a single
/// user message, and cleared it when the task ended - so reading email in one turn left
/// the next turn clean, and a search query in turn two could carry private content out.
/// The app papered over that by disabling web search after the first message entirely.
/// Holding the state per conversation lets web search keep working while still closing
/// the cross-turn path.
public final class PrivacyLedger {
    private var tainted: Set<UUID> = []
    private var conversationOfTask: [UUID: UUID] = [:]
    private var order: [UUID] = []
    private let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public func begin(task: UUID, conversation: UUID, carriesPrivateContent: Bool = false) {
        conversationOfTask[task] = conversation
        if !order.contains(conversation) {
            order.append(conversation)
            // Bound the ledger by forgetting the oldest conversations, never the newest.
            while order.count > capacity { tainted.remove(order.removeFirst()) }
        }
        if carriesPrivateContent { tainted.insert(conversation) }
    }
    /// Ending a task must not clear the taint: the conversation continues.
    public func endTask(_ task: UUID) { conversationOfTask.removeValue(forKey: task) }
    public func markPrivate(task: UUID) {
        guard let conversation = conversationOfTask[task] else { return }
        tainted.insert(conversation)
    }
    public func webAllowed(conversation: UUID) -> Bool { !tainted.contains(conversation) }
    public func webAllowed(task: UUID) -> Bool {
        guard let conversation = conversationOfTask[task] else { return false }
        return !tainted.contains(conversation)
    }
    public func forgetTasks() { conversationOfTask.removeAll() }
}
