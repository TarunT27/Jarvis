import Foundation

public enum JarvisError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public struct ChatMessage: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var role: String
    public var content: String
    public var created: Date = Date()
    /// Optional keeps records written by older Jarvis builds decodable.
    public var conversationID: UUID?
    public var statistics: GenerationStatistics?
    public var privateContext: Bool?
    public init(role: String, content: String, conversationID: UUID? = nil) {
        self.role = role; self.content = content; self.conversationID = conversationID
    }
}
public struct ConversationSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var preview: String
    public var created: Date
    public var updated: Date
    public var messageCount: Int
    public var projectID: UUID?

    public init(id: UUID, title: String = "New conversation", preview: String = "", created: Date = Date(), updated: Date = Date(), messageCount: Int = 0, projectID: UUID? = nil) {
        self.id = id; self.title = title; self.preview = preview; self.created = created
        self.updated = updated; self.messageCount = messageCount; self.projectID = projectID
    }
}
public struct JarvisProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), name: String, created: Date = Date(), updated: Date = Date()) {
        self.id = id; self.name = name; self.created = created; self.updated = updated
    }
}
public struct OrganizationState: Codable, Sendable {
    public var conversations: [ConversationSummary]
    public var projects: [JarvisProject]
    public var lastConversationID: UUID?

    public init(conversations: [ConversationSummary] = [], projects: [JarvisProject] = [], lastConversationID: UUID? = nil) {
        self.conversations = conversations; self.projects = projects; self.lastConversationID = lastConversationID
    }
}
public struct ToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var arguments: [String: String]
    public init(_ name: String, _ arguments: [String: String] = [:]) { self.name = name; self.arguments = arguments }
}
public struct ActionProposal: Codable, Identifiable, Sendable {
    public var id: UUID
    public var call: ToolCall
    public var expires: Date
    public var taskID: UUID
    /// Computer mutations are bound to the short-lived session that produced
    /// them.  Keeping this optional preserves decoding of proposals produced by
    /// older Jarvis builds and leaves ordinary approvals unchanged.
    public var computerSessionID: UUID?

    public init(id: UUID = UUID(), call: ToolCall, expires: Date, taskID: UUID, computerSessionID: UUID? = nil) {
        self.id = id
        self.call = call
        self.expires = expires
        self.taskID = taskID
        self.computerSessionID = computerSessionID
    }
}
/// The result of a supervised computer observation or action.  `image` is a
/// base64-encoded screenshot when the native worker has one; it is kept out of
/// chat history and broker audit records.
public struct ComputerObservation: Codable, Sendable, Equatable {
    public var text: String
    public var image: String?

    public init(text: String, image: String? = nil) {
        self.text = text
        self.image = image
    }
}
public struct BrokerReply: Codable, Sendable {
    public var result: String?
    /// Optional screenshot associated with `result`; absent on older replies
    /// and on all non-computer operations.
    public var image: String?
    public var proposal: ActionProposal?
    public var error: String?
    public init(result: String? = nil, image: String? = nil, proposal: ActionProposal? = nil, error: String? = nil) {
        self.result = result; self.image = image; self.proposal = proposal; self.error = error
    }
}
public enum Configuration {
    public static let appID = "local.jarvis.mac"
    public static let brokerID = "local.jarvis.mac.broker"
    public static let endpoint = URL(string: "http://127.0.0.1:11439")!
    public static let everyday = "qwen3.5:9b"
    public static let deep = "qwen3.8:27b"
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JarvisLocal", isDirectory: true)
    }
    /// Where Ollama keeps model weights.
    ///
    /// Defaults to the user's own store, so `ollama pull` and the Ollama app manage models
    /// normally and a 6-18 GB download is never duplicated per project. Jarvis still runs its
    /// own loopback-only server; only the weights are shared. Override with JARVIS_MODELS.
    public static var modelStore: URL {
        if let p = ProcessInfo.processInfo.environment["JARVIS_MODELS"] { return URL(fileURLWithPath: p) }
        // Ollama creates this on first pull, so an installed app needs no project fallback.
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
    }
    public static var project: URL {
        if let p = ProcessInfo.processInfo.environment["JARVIS_PROJECT"] { return URL(fileURLWithPath: p) }
        if let p = Bundle.main.object(forInfoDictionaryKey: "JarvisProjectRoot") as? String { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
@objc public protocol BrokerXPCProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}
public struct BrokerRequest: Codable {
    public var operation: String
    public var taskID: UUID?
    /// Groups the tasks of one conversation. Private-content taint lives at this
    /// scope, not per task, so reading email in one turn still blocks web search
    /// in the next. Cleared only by starting a new conversation.
    public var conversationID: UUID?
    public var call: ToolCall?
    public var proposal: ActionProposal?
    public var value: String?
    public init(_ operation: String, taskID: UUID? = nil, conversationID: UUID? = nil, call: ToolCall? = nil, proposal: ActionProposal? = nil, value: String? = nil) {
        self.operation = operation; self.taskID = taskID; self.conversationID = conversationID
        self.call = call; self.proposal = proposal; self.value = value
    }
}
