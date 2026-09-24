import Foundation

/// Skills, MCP servers and plugins, stored in the formats Claude uses so anything made
/// for Claude installs here unchanged:
///
///     extensions/skills/<name>/SKILL.md             Agent Skills
///     extensions/plugins/<name>/.claude-plugin/...   Claude Code plugins
///     extensions/mcp.json                            {"mcpServers": {...}} as in Claude Desktop
///     extensions/state.json                          what is switched off, and always-allowed tools
///
/// The app edits these; the broker reads them to serve use_skill and run MCP servers.
public struct ExtensionPaths: Sendable {
    public let root: URL
    public init(root: URL = Configuration.support.appendingPathComponent("extensions", isDirectory: true)) { self.root = root }
    public var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    public var mcp: URL { root.appendingPathComponent("mcp.json") }
    public var state: URL { root.appendingPathComponent("state.json") }
    /// Generated for Claude hand-offs: a plugin wrapping the user's own skills, and the MCP config.
    public var claudeBundle: URL { root.appendingPathComponent("claude-bundle", isDirectory: true) }
    public var claudeMCP: URL { root.appendingPathComponent("claude-mcp.json") }
}

public struct ExtensionState: Codable, Equatable, Sendable {
    public var disabledSkills: Set<String> = []
    public var disabledServers: Set<String> = []
    public var disabledPlugins: Set<String> = []
    /// "server/tool" pairs the user chose to run without an approval each time.
    public var alwaysAllow: Set<String> = []
    public var shareWithClaude = true
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledSkills = try c.decodeIfPresent(Set<String>.self, forKey: .disabledSkills) ?? []
        disabledServers = try c.decodeIfPresent(Set<String>.self, forKey: .disabledServers) ?? []
        disabledPlugins = try c.decodeIfPresent(Set<String>.self, forKey: .disabledPlugins) ?? []
        alwaysAllow = try c.decodeIfPresent(Set<String>.self, forKey: .alwaysAllow) ?? []
        shareWithClaude = try c.decodeIfPresent(Bool.self, forKey: .shareWithClaude) ?? true
    }
}

public struct Skill: Identifiable, Equatable, Sendable {
    /// "name" for the user's own skills, "plugin:name" for a plugin's.
    public let id: String
    public let name: String
    public let description: String
    public let folder: URL
    public let plugin: String?
}

public struct MCPServerConfig: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case stdio(command: String, args: [String], env: [String: String]), http(url: URL, headers: [String: String]) }
    /// Unique across sources: plugin servers are "plugin__server".
    public let id: String
    public let transport: Transport
    public let plugin: String?
    public var json: [String: Any] {
        switch transport {
        case .stdio(let command, let args, let env): var j: [String: Any] = ["command": command, "args": args]; if !env.isEmpty { j["env"] = env }; return j
        case .http(let url, let headers): var j: [String: Any] = ["type": "http", "url": url.absoluteString]; if !headers.isEmpty { j["headers"] = headers }; return j
        }
    }
}

public struct Plugin: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String
    public let description: String
    public let folder: URL
    public let skillCount: Int
    public let serverCount: Int
    public let commandCount: Int
}

public enum ExtensionFormat {
    public static let namePattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    /// The YAML front matter of a SKILL.md. Only the fields Jarvis needs are read, and
    /// only simple values: a scalar, a quoted string, or a folded/literal block.
    public static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:], key: String?, block: [String] = []
        func flush() { if let key, !block.isEmpty { fields[key] = block.joined(separator: " ") }; block = [] }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { flush(); break }
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") { if fields[k] == nil { block.append(line.trimmingCharacters(in: .whitespaces)) }; continue }
            flush(); key = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            key = k
            if v == ">" || v == "|" || v == ">-" || v == "|-" || v.isEmpty { continue }
            if (v.hasPrefix("\"") && v.hasSuffix("\"") || v.hasPrefix("'") && v.hasSuffix("'")) && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            fields[k] = v
        }
        return fields
    }

    public static func skill(at folder: URL, plugin: String?) -> Skill? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        let meta = frontMatter(text)
        let name = meta["name"] ?? folder.lastPathComponent
        let description = meta["description"] ?? ""
        return Skill(id: plugin.map { "\($0):\(name)" } ?? name, name: name, description: String(description.prefix(1_024)), folder: folder, plugin: plugin)
    }

    /// Accepts Claude Desktop's {"mcpServers": {...}} or a bare {"name": {...}} map.
    public static func servers(from data: Data, plugin: String? = nil) throws -> [MCPServerConfig] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JarvisError.message("MCP configuration must be a JSON object.") }
        let map = object["mcpServers"] as? [String: Any] ?? object
        return try map.keys.sorted().compactMap { name in
            guard let entry = map[name] as? [String: Any] else { return nil }
            let clean = sanitize(name)
            guard !clean.isEmpty else { throw JarvisError.message("Invalid server name \(name).") }
            let id = plugin.map { "\(sanitize($0))__\(clean)" } ?? clean
            if let command = entry["command"] as? String, !command.isEmpty {
                return MCPServerConfig(id: id, transport: .stdio(command: command, args: entry["args"] as? [String] ?? [],
                                                                 env: entry["env"] as? [String: String] ?? [:]), plugin: plugin)
            }
            if let text = entry["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return MCPServerConfig(id: id, transport: .http(url: url, headers: entry["headers"] as? [String: String] ?? [:]), plugin: plugin)
            }
            throw JarvisError.message("Server \(name) needs a command, or an http(s) url.")
        }
    }

    /// Skill and plugin folder names: "Dev Kit" becomes "dev-kit".
    public static func slug(_ name: String) -> String {
        let dashed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(dashed).split(separator: "-").joined(separator: "-").prefix(64))
    }

    /// Tool and server names become part of a tool name the model calls: keep them plain.
    public static func sanitize(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(40))
    }
}

/// Reads and changes the installed extensions. Used by the app (to manage) and the
/// broker (to serve). Every write goes through here so the layout stays consistent.
public final class ExtensionLibrary: @unchecked Sendable {
    public let paths: ExtensionPaths
    public init(paths: ExtensionPaths = ExtensionPaths()) { self.paths = paths }

    public func state() -> ExtensionState {
        guard let data = try? Data(contentsOf: paths.state) else { return ExtensionState() }
        return (try? JSONDecoder().decode(ExtensionState.self, from: data)) ?? ExtensionState()
    }
    public func save(_ state: ExtensionState) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: paths.state, options: .atomic)
    }

    public func plugins() -> [Plugin] {
        folders(in: paths.plugins).compactMap { folder in
            let manifest = folder.appendingPathComponent(".claude-plugin/plugin.json")
            let json = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            // The folder name is the identity (a slug of the manifest's name) everywhere:
            // switches, skill ids and server ids all key on it.
            let name = folder.lastPathComponent
            return Plugin(name: name, version: json["version"] as? String ?? "", description: json["description"] as? String ?? "",
                          folder: folder, skillCount: folders(in: folder.appendingPathComponent("skills")).count,
                          serverCount: (try? pluginServers(folder, name: name).count) ?? 0,
                          commandCount: ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("commands").path)) ?? []).filter { $0.hasSuffix(".md") }.count)
        }
    }

    /// The user's own skills, then those of enabled plugins.
    public func skills(includeDisabledPlugins: Bool = false) -> [Skill] {
        let off = state().disabledPlugins
        var all = folders(in: paths.skills).compactMap { ExtensionFormat.skill(at: $0, plugin: nil) }
        for plugin in plugins() where includeDisabledPlugins || !off.contains(plugin.name) {
            all += folders(in: plugin.folder.appendingPathComponent("skills")).compactMap { ExtensionFormat.skill(at: $0, plugin: plugin.name) }
        }
        return all
    }
    public func enabledSkills() -> [Skill] { let off = state().disabledSkills; return skills().filter { !off.contains($0.id) } }

    public func userServers() throws -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: paths.mcp) else { return [] }
        return try ExtensionFormat.servers(from: data)
    }
    /// Every configured server, user and plugin, with the ones switched off removed.
    public func enabledServers() -> [MCPServerConfig] {
        let state = state()
        var all = (try? userServers()) ?? []
        for plugin in plugins() where !state.disabledPlugins.contains(plugin.name) { all += (try? pluginServers(plugin.folder, name: plugin.name)) ?? [] }
        return all.filter { !state.disabledServers.contains($0.id) }
    }
    func pluginServers(_ folder: URL, name: String) throws -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".mcp.json")) else { return [] }
        return try ExtensionFormat.servers(from: data, plugin: name)
    }

    /// Adds or replaces servers in mcp.json from pasted JSON; returns the names added.
    @discardableResult public func addServers(json: String) throws -> [String] {
        let incoming = try ExtensionFormat.servers(from: Data(json.utf8))
        guard !incoming.isEmpty else { throw JarvisError.message("No servers found. Paste {\"mcpServers\": {\"name\": {\"command\": ...}}}.") }
        var map = (try? Data(contentsOf: paths.mcp)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mcpServers"] as? [String: Any] ?? [:]
        for server in incoming { map[server.id] = server.json }
        try writeServers(map)
        return incoming.map(\.id)
    }
    public func removeServer(_ id: String) throws {
        var map = (try? Data(contentsOf: paths.mcp)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mcpServers"] as? [String: Any] ?? [:]
        map.removeValue(forKey: id); try writeServers(map)
    }
    private func writeServers(_ map: [String: Any]) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": map], options: [.prettyPrinted, .sortedKeys]).write(to: paths.mcp, options: .atomic)
    }

    /// Writes a new skill in the Agent Skills format.
    @discardableResult public func createSkill(name: String, description: String, instructions: String) throws -> Skill {
        let name = ExtensionFormat.slug(name)
        guard name.range(of: ExtensionFormat.namePattern, options: .regularExpression) != nil else {
            throw JarvisError.message("Skill names are lowercase letters, numbers and dashes.")
        }
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else { throw JarvisError.message("Say when the skill should be used.") }
        let folder = paths.skills.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw JarvisError.message("A skill named \(name) already exists.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "---\nname: \(name)\ndescription: \(description.replacingOccurrences(of: "\n", with: " "))\n---\n\n\(instructions)\n"
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        guard let skill = ExtensionFormat.skill(at: folder, plugin: nil) else { throw JarvisError.message("The skill was written but could not be read back.") }
        return skill
    }

    /// Copies skill folders (each holding a SKILL.md) from a folder, a .zip, or a folder of skills.
    @discardableResult public func importSkills(from source: URL) throws -> [String] {
        let staged = try stage(source)
        defer { if staged.cleanup { try? FileManager.default.removeItem(at: staged.url) } }
        let candidates = FileManager.default.fileExists(atPath: staged.url.appendingPathComponent("SKILL.md").path) ? [staged.url] : folders(in: staged.url)
        var imported: [String] = []
        try FileManager.default.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        for folder in candidates {
            guard let skill = ExtensionFormat.skill(at: folder, plugin: nil) else { continue }
            let name = ExtensionFormat.slug(skill.name)
            let destination = paths.skills.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: folder, to: destination)
            imported.append(name)
        }
        guard !imported.isEmpty else { throw JarvisError.message("No SKILL.md was found there.") }
        return imported
    }

    /// Installs a Claude Code plugin from a folder or .zip (a Git clone is staged by the caller).
    @discardableResult public func installPlugin(from source: URL) throws -> Plugin {
        let staged = try stage(source)
        defer { if staged.cleanup { try? FileManager.default.removeItem(at: staged.url) } }
        var root = staged.url
        // A zip or clone often wraps everything in one top-level folder.
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude-plugin/plugin.json").path),
           let only = folders(in: root).first, folders(in: root).count == 1 { root = only }
        let manifest = root.appendingPathComponent(".claude-plugin/plugin.json")
        guard let data = try? Data(contentsOf: manifest), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["name"] as? String else {
            throw JarvisError.message("Not a plugin: .claude-plugin/plugin.json with a name is missing.")
        }
        let name = ExtensionFormat.slug(raw)
        guard name.range(of: ExtensionFormat.namePattern, options: .regularExpression) != nil else { throw JarvisError.message("The plugin's name is not usable.") }
        _ = try pluginServers(root, name: name)   // refuse a plugin whose .mcp.json is malformed
        try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        let destination = paths.plugins.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: root, to: destination)
        try? FileManager.default.removeItem(at: destination.appendingPathComponent(".git"))
        guard let installed = plugins().first(where: { $0.name == name }) else { throw JarvisError.message("The plugin was copied but could not be read back.") }
        return installed
    }

    public func removeSkill(_ skill: Skill) throws {
        guard skill.plugin == nil else { throw JarvisError.message("This skill comes with a plugin. Remove or switch off the plugin instead.") }
        try FileManager.default.removeItem(at: skill.folder)
    }
    public func removePlugin(_ plugin: Plugin) throws { try FileManager.default.removeItem(at: plugin.folder) }

    /// A plugin Claude Code can load that wraps the user's enabled skills, plus the
    /// enabled plugins themselves. Rebuilt on every hand-off so it matches the switches.
    public func claudePluginDirectories() -> [String] {
        guard state().shareWithClaude else { return [] }
        let fm = FileManager.default
        let bundle = paths.claudeBundle
        try? fm.removeItem(at: bundle)
        let own = enabledSkills().filter { $0.plugin == nil }
        var dirs: [String] = []
        if !own.isEmpty, (try? fm.createDirectory(at: bundle.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)) != nil {
            let manifest = ["name": "jarvis-skills", "version": "1.0.0", "description": "Skills installed in Jarvis"]
            try? JSONSerialization.data(withJSONObject: manifest).write(to: bundle.appendingPathComponent(".claude-plugin/plugin.json"))
            try? fm.createDirectory(at: bundle.appendingPathComponent("skills"), withIntermediateDirectories: true)
            for skill in own { try? fm.copyItem(at: skill.folder, to: bundle.appendingPathComponent("skills/\(skill.folder.lastPathComponent)")) }
            dirs.append(bundle.path)
        }
        let off = state().disabledPlugins
        dirs += plugins().filter { !off.contains($0.name) }.map(\.folder.path)
        return dirs
    }
    /// The user's own enabled servers for Claude; plugin servers arrive with their plugin.
    public func claudeMCPConfig() -> String? {
        let state = state()
        guard state.shareWithClaude else { return nil }
        let servers = ((try? userServers()) ?? []).filter { !state.disabledServers.contains($0.id) }
        guard !servers.isEmpty else { return nil }
        let map = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.json) })
        guard (try? JSONSerialization.data(withJSONObject: ["mcpServers": map], options: .prettyPrinted).write(to: paths.claudeMCP, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.claudeMCP.path)
        return paths.claudeMCP.path
    }

    private func folders(in url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// A folder is used in place; a .zip is expanded into a temporary folder first.
    private func stage(_ source: URL) throws -> (url: URL, cleanup: Bool) {
        guard source.pathExtension.lowercased() == "zip" else { return (source, false) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-ext-\(UUID().uuidString)")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", source.path, temp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw JarvisError.message("The zip could not be opened.") }
        try? FileManager.default.removeItem(at: temp.appendingPathComponent("__MACOSX"))
        return (temp, true)
    }
}
