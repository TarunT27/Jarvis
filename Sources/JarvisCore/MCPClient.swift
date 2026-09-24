import Foundation
import OSLog

/// Status only - server ids, methods and outcomes; never arguments or results.
let mcpLog = Logger(subsystem: "local.jarvis.mac", category: "mcp")

/// One tool an MCP server offers, under the name the local model calls it by.
public struct MCPTool: Sendable, Equatable {
    public let server: String
    public let name: String
    public let description: String
    /// The server's JSON Schema, re-serialized so it can cross actors and XPC.
    public let schema: String
    /// mcp__<server>__<tool>, the form the model sees.
    public var qualified: String { "mcp__\(server)__\(ExtensionFormat.sanitize(name))" }
    public var key: String { "\(server)/\(name)" }

    public var definition: [String: Any] {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]) ?? ["type": "object", "properties": [:]]
        let text = description.isEmpty ? "Tool \(name) from the \(server) MCP server." : description
        return ["type": "function", "function": ["name": qualified, "description": String(text.prefix(400)) + " (MCP server \(server); needs approval unless always allowed)",
                                                 "parameters": parameters]]
    }
}

public enum MCPProtocol {
    public static let version = "2025-06-18"

    /// Tool results as text for the model: text parts verbatim, anything else named.
    public static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "image": parts.append("[image \(item["mimeType"] as? String ?? "")]")
            case "audio": parts.append("[audio]")
            case "resource_link": parts.append("[resource \(item["uri"] as? String ?? "")]")
            case "resource":
                let resource = item["resource"] as? [String: Any] ?? [:]
                parts.append(resource["text"] as? String ?? "[resource \(resource["uri"] as? String ?? "")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) { parts.append(String(decoding: data, as: UTF8.self)) }
        let body = parts.joined(separator: "\n")
        return (result["isError"] as? Bool == true ? "The tool reported an error: " : "") + (body.isEmpty ? "(no output)" : body)
    }

    /// Streamable HTTP may answer with JSON or with a text/event-stream; find our reply either way.
    public static func response(in body: Data, contentType: String, id: Int) -> [String: Any]? {
        func matches(_ object: Any) -> [String: Any]? {
            if let one = object as? [String: Any], one["id"] as? Int == id { return one }
            if let many = object as? [[String: Any]] { return many.first { $0["id"] as? Int == id } }
            return nil
        }
        if contentType.contains("text/event-stream") {
            for line in String(decoding: body, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)), let found = matches(object) { return found }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: body)).flatMap(matches)
    }
}

/// A live connection to one MCP server. The broker owns these; every call it makes
/// has already passed policy and, unless the user always-allowed the tool, approval.
public actor MCPConnection {
    public nonisolated let config: MCPServerConfig
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var session: String?
    private var stderrTail = ""
    private var reader: Task<Void, Never>?

    public init(config: MCPServerConfig) { self.config = config }

    public func start() async throws -> [MCPTool] {
        if case .stdio(let command, let args, let env) = config.transport { try launch(command: command, args: args, env: env) }
        _ = try await request("initialize", ["protocolVersion": MCPProtocol.version, "capabilities": [:],
                                             "clientInfo": ["name": "Jarvis", "version": "0.2"]], timeout: 45)
        try await notify("notifications/initialized")
        var tools: [MCPTool] = [], cursor: String?
        repeat {
            let page = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            for tool in page["tools"] as? [[String: Any]] ?? [] {
                guard let name = tool["name"] as? String else { continue }
                let schema = (tool["inputSchema"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                tools.append(MCPTool(server: config.id, name: name, description: tool["description"] as? String ?? "", schema: schema))
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        mcpLog.info("\(self.config.id, privacy: .public) ready with \(tools.count) tools")
        return tools
    }

    public func call(tool: String, arguments: [String: Any]) async throws -> String {
        let result = try await request("tools/call", ["name": tool, "arguments": arguments], timeout: 180)
        return MCPProtocol.text(of: result)
    }

    public func stop() {
        for (_, continuation) in pending { continuation.resume(throwing: JarvisError.message("The MCP server stopped.")) }
        pending.removeAll()
        if let process, process.isRunning { process.terminate() }
        reader?.cancel(); reader = nil
        process = nil; input = nil
    }

    // MARK: transport

    private func launch(command: String, args: [String], env: [String: String]) throws {
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        // Servers are usually npx/uvx/node scripts; an XPC service's PATH has none of their homes.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"] ?? ""].joined(separator: ":")
        env.forEach { environment[$0.key] = $0.value }
        p.environment = environment
        if command.contains("/") { p.executableURL = URL(fileURLWithPath: (command as NSString).expandingTildeInPath); p.arguments = args }
        else { p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = [command] + args }
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        // One reader in order. A Task per chunk would not preserve ordering and could
        // splice two JSON-RPC messages together.
        let lines = stdout.fileHandleForReading.bytes.lines
        reader = Task { [weak self] in
            do { for try await line in lines { await self?.receive(line) } } catch {}
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            Task { await self.noteError(text) }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.exited() } }
        try p.run()
        mcpLog.info("launched \(self.config.id, privacy: .public) pid \(p.processIdentifier)")
        process = p; input = stdin.fileHandleForWriting
    }

    private func noteError(_ text: String) { stderrTail = String((stderrTail + text).suffix(600)) }
    private func exited() {
        mcpLog.info("\(self.config.id, privacy: .public) exited with \(self.pending.count) pending")
        let reason = stderrTail.split(separator: "\n").last.map(String.init) ?? ""
        for (_, continuation) in pending { continuation.resume(throwing: JarvisError.message("The MCP server exited. \(reason)")) }
        pending.removeAll(); process = nil; input = nil
    }

    private func receive(_ line: String) {
        // Notifications, server-to-client requests and log noise are ignored.
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = message["id"] as? Int,
              let continuation = pending.removeValue(forKey: id) else { mcpLog.debug("\(self.config.id, privacy: .public) sent a line that is not a pending reply");return }
        mcpLog.info("\(self.config.id, privacy: .public) replied to request \(id)")
        resolve(continuation, with: message)
    }

    private func resolve(_ continuation: CheckedContinuation<[String: Any], Error>, with message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: JarvisError.message("MCP error: \(error["message"] as? String ?? "unknown")"))
        } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if case .http(let url, let headers) = config.transport { return try await post(body, id: id, url: url, headers: headers, timeout: timeout) }
        guard let input else { throw JarvisError.message("The MCP server is not running.") }
        var data = try JSONSerialization.data(withJSONObject: body); data.append(10)
        mcpLog.info("\(self.config.id, privacy: .public) request \(id) \(method, privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) } catch { pending.removeValue(forKey: id); continuation.resume(throwing: error); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, method: method)
            }
        }
    }
    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: JarvisError.message("The MCP server did not answer \(method) in time."))
    }

    private func notify(_ method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if case .http(let url, let headers) = config.transport { _ = try? await post(body, id: nil, url: url, headers: headers, timeout: 15); return }
        guard let input else { return }
        var data = try JSONSerialization.data(withJSONObject: body); data.append(10)
        try input.write(contentsOf: data)
    }

    private func post(_ body: [String: Any], id: Int?, url: URL, headers: [String: String], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPProtocol.version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JarvisError.message("No response from the MCP server.") }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = assigned }
        guard (200..<300).contains(http.statusCode) else {
            throw JarvisError.message(http.statusCode == 401 ? "The MCP server needs sign-in (401). Add its token under headers." : "The MCP server answered HTTP \(http.statusCode).")
        }
        guard let id else { return [:] }
        guard let message = MCPProtocol.response(in: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", id: id) else {
            throw JarvisError.message("The MCP server's reply could not be read.")
        }
        if let error = message["error"] as? [String: Any] { throw JarvisError.message("MCP error: \(error["message"] as? String ?? "unknown")") }
        return message["result"] as? [String: Any] ?? [:]
    }
}
