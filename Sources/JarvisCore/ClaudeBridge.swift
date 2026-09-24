import Foundation

/// Hand-off to Claude through the Claude Code CLI the Claude app installs.
///
/// This is the one path by which Jarvis sends work off the Mac, so everything about
/// it is explicit: the local model only *suggests* a hand-off, the user sees and can
/// edit the exact prompt, and picks the model and effort, before anything is sent.
/// It uses the user's own Claude login; Jarvis holds no Anthropic credential.
public enum ClaudeCatalog {
    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let note: String
    }
    public static let models: [Model] = [
        Model(id: "claude-opus-5-5", name: "Opus 5.5", note: "hardest reasoning and large builds"),
        Model(id: "claude-sonnet-5", name: "Sonnet 5", note: "strong everyday coding and writing"),
        Model(id: "claude-fable-5-1", name: "Fable 5.1", note: "long-form writing and storytelling"),
        Model(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", note: "fast, light questions"),
    ]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public static func name(of model: String) -> String { models.first { $0.id == model }?.name ?? model }

    /// A starting point when the user opens the card without the local model's help.
    public static func suggestion(prompt: String, building: Bool) -> (model: String, effort: String, reason: String) {
        if building { return ("claude-opus-5-5", "xhigh", "A build touches many files and needs to verify its own work.") }
        let lower = prompt.lowercased()
        let hard = ["prove", "architecture", "design", "debug", "optimi", "algorithm", "research", "analy", "plan", "strategy"]
        if prompt.count > 1_500 || hard.contains(where: lower.contains) {
            return ("claude-opus-5-5", "high", "Long or reasoning-heavy request.")
        }
        if prompt.count < 200 { return ("claude-haiku-4-5-20251001", "low", "Short, simple question.") }
        return ("claude-sonnet-5", "medium", "Ordinary question that is more than the local model should guess at.")
    }
}

public enum ClaudePolicy {
    public static let projectPattern = "^[A-Za-z0-9][A-Za-z0-9 _.-]{0,59}$"

    /// Shape checks for the model's ask_claude suggestion. The user edits and confirms
    /// the result before anything is sent, so this guards the card, not the network.
    public static func validate(_ call: ToolCall) throws {
        let a = call.arguments
        guard let prompt = a["prompt"], prompt.utf8.count <= 48_000 else { throw JarvisError.message("The prompt for Claude is limited to 48 KB.") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JarvisError.message("Write the prompt Claude should receive.") }
        guard ClaudeCatalog.models.contains(where: { $0.id == a["model"] }) else {
            throw JarvisError.message("model must be one of: " + ClaudeCatalog.models.map(\.id).joined(separator: ", "))
        }
        guard ClaudeCatalog.efforts.contains(a["effort"] ?? "") else { throw JarvisError.message("effort must be low, medium, high, xhigh or max.") }
        if let project = a["project"], !project.isEmpty, project.range(of: projectPattern, options: .regularExpression) == nil {
            throw JarvisError.message("A project name is letters, numbers, spaces, dots, dashes or underscores, up to 60 characters.")
        }
        guard (a["reason"] ?? "").count <= 300 else { throw JarvisError.message("Keep the reason to one sentence.") }
    }
}

/// Named project folders Claude may build in. The model can only name a project; it
/// can never point Claude at an arbitrary path. New projects live under ~/Jarvis Builds;
/// existing folders are added by the user through a folder picker.
public struct ClaudeProject: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name.lowercased() }
    public var name: String
    public var path: String
    public var sessionID: String?
    public var created: Date
    public var updated: Date
    public init(name: String, path: String, sessionID: String? = nil, created: Date = Date(), updated: Date = Date()) {
        self.name = name; self.path = path; self.sessionID = sessionID; self.created = created; self.updated = updated
    }
}

public final class ClaudeProjectStore: @unchecked Sendable {
    private let file: URL
    public let buildsRoot: URL
    private let lock = NSLock()

    public init(file: URL = Configuration.support.appendingPathComponent("claude-projects.json"),
                buildsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jarvis Builds", isDirectory: true)) {
        self.file = file; self.buildsRoot = buildsRoot
    }

    public func all() -> [ClaudeProject] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }
    public func find(_ name: String) -> ClaudeProject? {
        all().first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
    public func folder(forNew name: String) -> URL { buildsRoot.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true) }

    /// Returns the project, creating its folder under ~/Jarvis Builds when it is new.
    @discardableResult public func open(_ name: String) throws -> ClaudeProject {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name.range(of: ClaudePolicy.projectPattern, options: .regularExpression) != nil else { throw JarvisError.message("Invalid project name.") }
        if let existing = find(name) { return existing }
        let folder = folder(forNew: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = ClaudeProject(name: name, path: folder.path)
        try update { $0.append(project) }
        return project
    }
    /// Registers a folder the user chose, under a name they can say out loud.
    @discardableResult public func add(name: String, folder: URL) throws -> ClaudeProject {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name.range(of: ClaudePolicy.projectPattern, options: .regularExpression) != nil else { throw JarvisError.message("Use a short project name.") }
        guard find(name) == nil else { throw JarvisError.message("A project named \(name) already exists.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw JarvisError.message("Choose a folder.") }
        let project = ClaudeProject(name: name, path: folder.standardizedFileURL.path)
        try update { $0.append(project) }
        return project
    }
    public func remember(session: String, for name: String) {
        try? update { list in
            if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                list[i].sessionID = session; list[i].updated = Date()
            }
        }
    }
    /// Forgets the project; its folder and files are left exactly where they are.
    public func remove(_ name: String) { try? update { $0.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } } }

    private func load() -> [ClaudeProject] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClaudeProject].self, from: data)) ?? []
    }
    private func update(_ change: (inout [ClaudeProject]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var list = load(); change(&list)
        list.sort { $0.updated > $1.updated }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(list).write(to: file, options: .atomic)
    }
}

/// What the user confirmed on the hand-off card.
public struct ClaudeHandoff: Sendable, Equatable {
    public var prompt: String
    public var model: String
    public var effort: String
    /// nil answers only; a project builds inside its folder.
    public var projectPath: String?
    public var resumeSession: String?
    public var pluginDirectories: [String] = []
    public var mcpConfig: String?
    public init(prompt: String, model: String, effort: String, projectPath: String? = nil, resumeSession: String? = nil,
                pluginDirectories: [String] = [], mcpConfig: String? = nil) {
        self.prompt = prompt; self.model = model; self.effort = effort; self.projectPath = projectPath
        self.resumeSession = resumeSession; self.pluginDirectories = pluginDirectories; self.mcpConfig = mcpConfig
    }
}

public enum ClaudeCLI {
    /// The newest Claude Code bundled with the Claude app, then any standalone install.
    public static func locate() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["JARVIS_CLAUDE"], fm.isExecutableFile(atPath: override) { return URL(fileURLWithPath: override) }
        let bundled = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let binary = bundled.appendingPathComponent("\(version)/claude.app/Contents/MacOS/claude")
            if fm.isExecutableFile(atPath: binary.path) { return binary }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static let instructions = """
    You are being run by Jarvis, the user's local macOS assistant, on the user's behalf. The user reviewed this prompt before it was sent. \
    Work autonomously; you cannot ask follow-up questions in this mode, so make reasonable choices and state them. \
    Finish with a short Markdown summary: what you did, the files you created or changed, and how to run or use the result.
    """

    /// Answer-only runs get no file or shell tools. Builds may edit and run commands in
    /// their project folder only: Claude Code's macOS sandbox confines Bash writes to the
    /// working directory (and temporary folders), and acceptEdits only covers files there.
    public static func arguments(for handoff: ClaudeHandoff) -> [String] {
        var args = ["-p", handoff.prompt, "--output-format", "stream-json", "--verbose",
                    "--model", handoff.model, "--effort", handoff.effort, "--append-system-prompt", instructions]
        if handoff.projectPath != nil {
            args += ["--permission-mode", "acceptEdits", "--allowedTools", "Bash",
                     "--settings", #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}"#]
        } else {
            args += ["--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit"]
        }
        if let session = handoff.resumeSession { args += ["--resume", session] }
        for plugin in handoff.pluginDirectories { args += ["--plugin-dir", plugin] }
        if let mcp = handoff.mcpConfig { args += ["--mcp-config", mcp] }
        return args
    }
}

/// One line of Claude Code's stream-json output, reduced to what Jarvis shows.
public enum ClaudeEvent: Equatable, Sendable {
    case started(session: String, model: String)
    case text(String)
    case activity(String)
    case finished(result: String, session: String, isError: Bool, seconds: Double, cost: Double?)
}

public enum ClaudeStream {
    public static func parse(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8), let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch e["type"] as? String {
        case "system" where e["subtype"] as? String == "init":
            return [.started(session: e["session_id"] as? String ?? "", model: e["model"] as? String ?? "")]
        case "assistant":
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { part in
                switch part["type"] as? String {
                case "text": return (part["text"] as? String).flatMap { $0.isEmpty ? nil : .text($0) }
                case "tool_use": return .activity(describe(tool: part["name"] as? String ?? "tool", input: part["input"] as? [String: Any] ?? [:]))
                default: return nil
                }
            }
        case "result":
            return [.finished(result: e["result"] as? String ?? "", session: e["session_id"] as? String ?? "",
                              isError: e["is_error"] as? Bool ?? (e["subtype"] as? String != "success"),
                              seconds: (e["duration_ms"] as? Double ?? 0) / 1000, cost: e["total_cost_usd"] as? Double)]
        default: return []
        }
    }

    /// "Writing index.html", "Running npm test": one short line per tool use.
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String { ((input[key] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "" }
        func clip(_ s: String) -> String { let one = s.replacingOccurrences(of: "\n", with: " "); return one.count > 70 ? String(one.prefix(69)) + "…" : one }
        switch tool {
        case "Write": return "Writing \(file("file_path"))"
        case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
        case "Read": return "Reading \(file("file_path"))"
        case "Bash": return "Running `\(clip(input["command"] as? String ?? ""))`"
        case "Glob", "Grep": return "Searching \(clip(input["pattern"] as? String ?? ""))"
        case "WebSearch": return "Searching the web for \(clip(input["query"] as? String ?? ""))"
        case "WebFetch": return "Reading \(clip(input["url"] as? String ?? "a web page"))"
        case "TodoWrite": return "Planning the steps"
        case "Task", "Agent": return "Delegating a subtask"
        default: return tool.hasPrefix("mcp__") ? "Using \(tool.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " "))" : "Using \(tool)"
        }
    }
}
