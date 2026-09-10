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
    public init(role: String, content: String) { self.role = role; self.content = content }
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
}
public struct BrokerReply: Codable, Sendable {
    public var result: String?
    public var proposal: ActionProposal?
    public var error: String?
    public init(result: String? = nil, proposal: ActionProposal? = nil, error: String? = nil) {
        self.result = result; self.proposal = proposal; self.error = error
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
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
        if FileManager.default.fileExists(atPath: shared.appendingPathComponent("manifests").path) { return shared }
        return project.appendingPathComponent(".runtime/ollama-models")
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
    public var call: ToolCall?
    public var proposal: ActionProposal?
    public var value: String?
    public init(_ operation: String, taskID: UUID? = nil, call: ToolCall? = nil, proposal: ActionProposal? = nil, value: String? = nil) {
        self.operation = operation; self.taskID = taskID; self.call = call; self.proposal = proposal; self.value = value
    }
}
