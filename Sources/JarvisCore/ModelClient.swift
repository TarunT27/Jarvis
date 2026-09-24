import Foundation

public struct ModelResponse: Sendable {
    public var content: String
    public var tools: [ToolCall]
    public var statistics: GenerationStatistics?
}
public actor ModelClient {
    private let session: URLSession
    /// Model downloads run for many minutes; only a stalled one should time out.
    private let downloads: URLSession
    private var loaded: String?
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120; c.timeoutIntervalForResource = 300
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c)
        let d = URLSessionConfiguration.ephemeral
        d.timeoutIntervalForRequest = 300; d.timeoutIntervalForResource = 24 * 3600
        d.connectionProxyDictionary = [:]
        downloads = URLSession(configuration: d)
    }
    public func installed() async throws -> [String] {
        let (d,r) = try await session.data(from: Configuration.endpoint.appendingPathComponent("api/tags"))
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw JarvisError.message("Local model service is not ready.") }
        let json = try JSONSerialization.jsonObject(with:d) as? [String:Any]
        return (json?["models"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }
    }
    public func unload() async {
        guard let model = loaded else { return }
        var req = URLRequest(url: Configuration.endpoint.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model":model,"keep_alive":0])
        _ = try? await session.data(for:req); loaded = nil
    }
    /// Downloads one of the configured models through the local server, reporting the
    /// fraction done. Only configured names are accepted, like every other call here.
    public func pull(model: String, progress: @escaping @Sendable (Double, String) async -> Void) async throws {
        guard [Configuration.everyday, Configuration.deep].contains(model) else { throw JarvisError.message("Only configured local models can be downloaded.") }
        var request = URLRequest(url: Configuration.endpoint.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await downloads.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JarvisError.message("The local model service refused the download.") }
        // Ollama reports per-layer progress; the weights layer dominates, so report the largest.
        var total = 0.0, completed = 0.0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let j = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = j["error"] as? String { throw JarvisError.message("Model download failed: \(error)") }
            let status = j["status"] as? String ?? ""
            if let t = j["total"] as? Double, t >= total { total = t; completed = j["completed"] as? Double ?? 0 }
            await progress(total > 0 ? min(1, completed / total) : 0, status)
            if status == "success" { return }
        }
        throw JarvisError.message("The model download ended early. Try again; it resumes where it stopped.")
    }
    /// Capabilities come from the installed local model, not a model-name guess.
    public func capabilities(model: String) async throws -> Set<String> {
        guard [Configuration.everyday, Configuration.deep].contains(model) else {
            throw JarvisError.message("Only configured local models are allowed.")
        }
        var request = URLRequest(url: Configuration.endpoint.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = object["capabilities"] as? [String] else {
            throw JarvisError.message("Could not check the installed model's capabilities. Check the local runtime and model installation.")
        }
        return Set(capabilities)
    }
    public func respond(model: String, messages: [[String:Any]], tools: [[String:Any]], keepWarm: Bool, options: GenerationOptions = GenerationOptions(), onToken: @escaping @Sendable (String) async -> Void) async throws -> ModelResponse {
        guard [Configuration.everyday,Configuration.deep].contains(model) else { throw JarvisError.message("Only configured local models are allowed.") }
        let options = try options.validated()
        if let loaded, loaded != model { await unload() }
        loaded = model
        var req = URLRequest(url: Configuration.endpoint.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String:Any] = ["model":model,"messages":messages,"stream":true,"think":model == Configuration.deep,"keep_alive":keepWarm ? -1 : 300,
            "options":["num_ctx":8192,"num_predict":options.maximumTokens,"temperature":options.temperature]]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject:body)
        let (bytes,response) = try await session.bytes(for:req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JarvisError.message("Local model request failed. Check that the selected model is installed.") }
        var content = ""; var calls: [ToolCall] = []
        var statistics: GenerationStatistics?
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using:.utf8), let j = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { continue }
            if j["error"] != nil { throw JarvisError.message("The local model reported an inference error.") }
            if j["done"] as? Bool == true {
                completed = true; statistics = GenerationStatistics(model:model,response:j)
            }
            if let m = j["message"] as? [String:Any] {
                if let token = m["content"] as? String { content += token; await onToken(token) }
                for raw in m["tool_calls"] as? [[String:Any]] ?? [] {
                    // MCP tools take typed JSON; it travels as one "_json" string through the
                    // string-only contract and the broker checks it is a single object.
                    if let f = raw["function"] as? [String:Any], let name = f["name"] as? String, name.hasPrefix("mcp__") {
                        let args = f["arguments"] as? [String:Any] ?? [:]
                        let data = try JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys])
                        calls.append(ToolCall(name, ["_json": String(decoding: data, as: UTF8.self)])); continue
                    }
                    guard let f = raw["function"] as? [String:Any], let name = f["name"] as? String,
                          let args = f["arguments"] as? [String:Any], args.values.allSatisfy({ $0 is String }) else { throw JarvisError.message("Model returned invalid tool arguments.") }
                    calls.append(ToolCall(name,args.mapValues { $0 as! String }))
                }
            }
        }
        guard completed else { throw JarvisError.message("The local model stream ended before completion. No pending tool calls were executed.") }
        return ModelResponse(content:content,tools:calls,statistics:statistics)
    }
}
