import Foundation

/// User-authored, data-only workspace content. It never grants a tool permission.
public struct WorkspaceItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case note, prompt }
    public var id: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var updated: Date
    public init(id: UUID = UUID(), kind: Kind, title: String, body: String, updated: Date = Date()) {
        self.id=id; self.kind=kind; self.title=title; self.body=body; self.updated=updated
    }
    public func validated() throws -> Self {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 160, body.utf8.count <= 32_000,
              !title.contains("\0"), !body.contains("\0") else {
            throw JarvisError.message("Use a title up to 160 bytes and content up to 32 KB, without null characters.")
        }
        return self
    }
    /// Only predictable, local variables; never expands clipboard, files, or commands.
    public func expanded(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let format=ISO8601DateFormatter(); format.timeZone=timeZone
        return body.replacingOccurrences(of:"{{date}}",with:String(format.string(from:now).prefix(10)))
            .replacingOccurrences(of:"{{time}}",with:format.string(from:now))
            .replacingOccurrences(of:"{{timezone}}",with:timeZone.identifier)
    }
}

public enum WorkspaceStore {
    private static func key(_ id: UUID) -> String { "workspace:"+id.uuidString }
    public static func list(_ vault: Vault) throws -> [WorkspaceItem] {
        try vault.rows(kind:"workspace",limit:500).map { row in
            guard let body=row["body"] else { throw JarvisError.message("Workspace record is incomplete.") }
            return try JSONDecoder().decode(WorkspaceItem.self,from:Data(body.utf8)).validated()
        }.sorted { $0.updated > $1.updated }
    }
    public static func save(_ item: WorkspaceItem, in vault: Vault) throws {
        var item=try item.validated(); item.updated=Date()
        let items=try list(vault)
        guard items.contains(where:{$0.id==item.id}) || items.count<500 else {
            throw JarvisError.message("The workspace is limited to 500 items. Export and remove unused items first.")
        }
        let data=try JSONEncoder().encode(item)
        try vault.put(kind:"workspace",body:String(decoding:data,as:UTF8.self),id:key(item.id),durable:true)
    }
    public static func delete(_ id: UUID, from vault: Vault) throws {
        guard try list(vault).contains(where:{$0.id==id}) else { throw JarvisError.message("Workspace item no longer exists.") }
        try vault.delete(id:key(id))
    }
}

/// Kept in the encrypted database, independently of the bounded in-memory task ledger.
public enum ConversationPrivacy {
    public static func isPrivate(_ id: UUID, in vault: Vault) throws -> Bool {
        !(try vault.rows(kind:"conversation_privacy",limit:1,id:"private:"+id.uuidString)).isEmpty
    }
    public static func mark(_ id: UUID, in vault: Vault) throws {
        try vault.put(kind:"conversation_privacy",body:"private",id:"private:"+id.uuidString,durable:true)
    }
}

public struct GenerationOptions: Codable, Equatable, Sendable {
    public var temperature: Double = 0.2
    public var maximumTokens: Int = 1024
    public init() {}
    public func validated() throws -> Self {
        guard temperature.isFinite, (0...1).contains(temperature), (128...2048).contains(maximumTokens) else {
            throw JarvisError.message("Generation limits: temperature 0–1, response length 128–2048 tokens.")
        }
        return self
    }
}

public struct GenerationStatistics: Codable, Equatable, Sendable {
    public var model: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalSeconds: Double?
    public var generationSeconds: Double?
    public var tokensPerSecond: Double? {
        guard let count=outputTokens, let seconds=generationSeconds, seconds>0 else { return nil }
        return Double(count)/seconds
    }
    public init(model: String, response: [String:Any]) {
        self.model=model
        inputTokens=(response["prompt_eval_count"] as? Int).flatMap { $0>=0 ? $0:nil }
        outputTokens=(response["eval_count"] as? Int).flatMap { $0>=0 ? $0:nil }
        func seconds(_ key: String) -> Double? {
            guard let value=response[key] as? Double, value.isFinite, value>=0 else { return nil }
            return value/1_000_000_000
        }
        totalSeconds=seconds("total_duration"); generationSeconds=seconds("eval_duration")
    }
}

public struct ConversationExport: Codable, Sendable {
    public var format = "jarvis-conversation"
    public var version = 1
    public var title: String
    public var exported: Date
    public var messages: [ChatMessage]
    public init(title: String, messages: [ChatMessage]) {
        self.title=title; self.messages=messages; exported=Date()
    }
    public var markdown: String {
        "# \(title)\n\n" + messages.map { "## \($0.role == "user" ? "You" : "Jarvis")\n\n\($0.content)\n" }.joined(separator:"\n")
    }
}
