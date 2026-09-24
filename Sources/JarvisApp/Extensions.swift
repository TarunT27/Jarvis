import Foundation
import AppKit
import JarvisCore

/// What the Extensions page shows and changes. The files are the source of truth
/// (ExtensionLibrary); the broker owns the running MCP servers and reports on them.
@MainActor @Observable final class ExtensionStore {
    struct ServerRow: Identifiable, Equatable {
        struct Tool: Identifiable, Equatable { var id:String { key };let name:String;let key:String;let description:String;var always:Bool }
        let id:String
        let status:String
        let plugin:String?
        let enabled:Bool
        let editable:Bool
        var tools:[Tool]
    }
    private(set) var skills:[Skill]=[]
    private(set) var plugins:[Plugin]=[]
    private(set) var servers:[ServerRow]=[]
    private(set) var state=ExtensionState()
    /// Tool definitions from running MCP servers, as the local model receives them.
    private(set) var toolDefinitions:[[String:Any]]=[]
    var message:String?
    var working=false
    @ObservationIgnored let library=ExtensionLibrary()
    @ObservationIgnored weak var broker:BrokerClient?
    /// More than this and a 9B model starts choosing tools badly; the page says so.
    static let modelToolBudget=40

    func attach(_ broker:BrokerClient) { self.broker=broker }

    func reloadFiles() {
        state=library.state()
        skills=library.skills(includeDisabledPlugins:false)
        plugins=library.plugins()
    }

    /// Re-reads files, then asks the broker for server status a few times while servers start.
    func refresh(restartServers:Bool=false) async {
        reloadFiles()
        guard let broker else { return }
        if restartServers { _=try? await broker.request(BrokerRequest("extensions_reload")) }
        // Servers start in the broker concurrently; poll briefly until none says Starting.
        for attempt in 0..<8 {
            if attempt>0 { try? await Task.sleep(for:.milliseconds(700)) }
            await readStatus(broker)
            if !servers.contains(where:{ $0.status=="Starting" }) { break }
        }
    }

    private func readStatus(_ broker:BrokerClient) async {
        guard let reply=try? await broker.request(BrokerRequest("mcp_status")),let data=reply.result?.data(using:.utf8),
              let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        toolDefinitions=json["definitions"] as? [[String:Any]] ?? []
        var live:[String:(String,[ServerRow.Tool])]=[:]
        for server in json["servers"] as? [[String:Any]] ?? [] {
            guard let id=server["id"] as? String else { continue }
            let tools=(server["tools"] as? [[String:Any]] ?? []).compactMap { t -> ServerRow.Tool? in
                guard let name=t["name"] as? String,let key=t["key"] as? String else { return nil }
                return ServerRow.Tool(name:name,key:key,description:t["description"] as? String ?? "",always:t["always"] as? Bool ?? false)
            }
            live[id]=(server["status"] as? String ?? "",tools)
        }
        // Every configured server shows, running or not, so a switched-off one can be switched back on.
        var rows:[ServerRow]=[]
        let own=(try? library.userServers()) ?? []
        for config in own { rows.append(row(config,live:live,editable:true)) }
        for plugin in plugins where !state.disabledPlugins.contains(plugin.name) {
            let configs=library.enabledServers().filter { $0.plugin==plugin.name }
            for config in configs { rows.append(row(config,live:live,editable:false)) }
            for id in state.disabledServers where id.hasPrefix("\(ExtensionFormat.sanitize(plugin.name))__") && !configs.contains(where:{ $0.id==id }) {
                rows.append(ServerRow(id:id,status:"Off",plugin:plugin.name,enabled:false,editable:false,tools:[]))
            }
        }
        servers=rows
    }
    private func row(_ config:MCPServerConfig,live:[String:(String,[ServerRow.Tool])],editable:Bool) -> ServerRow {
        let enabled = !state.disabledServers.contains(config.id)
        return ServerRow(id:config.id,status:enabled ? (live[config.id]?.0 ?? "Not started") : "Off",plugin:config.plugin,
                         enabled:enabled,editable:editable,tools:live[config.id]?.1 ?? [])
    }

    // MARK: switches

    private func change(_ edit:(inout ExtensionState)->Void,restart:Bool) {
        var s=library.state();edit(&s)
        do { try library.save(s) } catch { message=error.localizedDescription }
        Task { await refresh(restartServers:restart) }
    }
    private static func set(_ set:inout Set<String>,_ id:String,off:Bool) { if off { set.insert(id) } else { set.remove(id) } }
    func setSkill(_ skill:Skill,enabled:Bool) { change({ Self.set(&$0.disabledSkills,skill.id,off:!enabled) },restart:false) }
    func setServer(_ id:String,enabled:Bool) { change({ Self.set(&$0.disabledServers,id,off:!enabled) },restart:true) }
    func setPlugin(_ plugin:Plugin,enabled:Bool) { change({ Self.set(&$0.disabledPlugins,plugin.name,off:!enabled) },restart:true) }
    func setShareWithClaude(_ on:Bool) { change({ $0.shareWithClaude=on },restart:false) }
    func setAlways(_ key:String,_ on:Bool) {
        var s=library.state()
        if on { s.alwaysAllow.insert(key) } else { s.alwaysAllow.remove(key) }
        do { try library.save(s) } catch { message=error.localizedDescription;return }
        Task { _=try? await broker?.request(BrokerRequest("extensions_permissions"));await refresh() }
    }

    // MARK: installing

    private func perform(_ what:String,restart:Bool=false,_ body:@escaping () throws -> String) {
        working=true;message=nil
        Task {
            do { message=try body() } catch { message="\(what) failed: \(error.localizedDescription)" }
            working=false
            await refresh(restartServers:restart)
        }
    }
    func createSkill(name:String,description:String,instructions:String) {
        perform("Creating the skill") { "Created “\(try self.library.createSkill(name:name,description:description,instructions:instructions).name)”." }
    }
    func importSkills(from url:URL) { perform("Import") { "Imported "+(try self.library.importSkills(from:url)).joined(separator:", ")+"." } }
    var claudeSkillsFolder:URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills") }
    func importClaudeSkills() { importSkills(from:claudeSkillsFolder) }
    func remove(_ skill:Skill) { perform("Removing the skill") { try self.library.removeSkill(skill);return "Removed \(skill.name)." } }
    func addServers(json:String) {
        perform("Adding the server",restart:true) { "Added "+(try self.library.addServers(json:json)).joined(separator:", ")+". Starting…" }
    }
    func removeServer(_ id:String) { perform("Removing the server",restart:true) { try self.library.removeServer(id);return "Removed \(id)." } }
    /// Claude Desktop keeps its servers in the same format, so they can come across as-is.
    func importClaudeDesktopServers() {
        let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        perform("Import",restart:true) {
            let data=try Data(contentsOf:url)
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard let map=object?["mcpServers"] as? [String:Any],!map.isEmpty else { return "Claude Desktop has no MCP servers configured." }
            let json=String(decoding:try JSONSerialization.data(withJSONObject:["mcpServers":map]),as:UTF8.self)
            return "Imported "+(try self.library.addServers(json:json)).joined(separator:", ")+"."
        }
    }
    func installPlugin(from url:URL) { perform("Install",restart:true) { "Installed \(try self.library.installPlugin(from:url).name)." } }
    /// A shallow clone into a temporary folder, then the same install as a local folder.
    func installPlugin(git:String) {
        let address=git.trimmingCharacters(in:.whitespaces)
        guard let url=URL(string:address),["https","http"].contains(url.scheme?.lowercased() ?? ""),url.host != nil else {
            message="Use an https Git address, for example https://github.com/owner/plugin.git";return
        }
        perform("Install",restart:true) {
            let temp=FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-plugin-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at:temp) }
            let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/git");p.arguments=["clone","--depth","1","--quiet",address,temp.path]
            p.environment=["GIT_TERMINAL_PROMPT":"0","PATH":"/usr/bin:/bin"]
            try p.run();p.waitUntilExit()
            guard p.terminationStatus==0 else { throw JarvisError.message("git could not clone \(address).") }
            return "Installed \(try self.library.installPlugin(from:temp).name)."
        }
    }
    func remove(_ plugin:Plugin) { perform("Removing the plugin",restart:true) { try self.library.removePlugin(plugin);return "Removed \(plugin.name)." } }
    func reveal(_ url:URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: what the model and Claude get

    /// Enabled skills for the system prompt: name and description only; use_skill loads the rest.
    var skillCatalog:String {
        let enabled=skills.filter { !state.disabledSkills.contains($0.id) }.prefix(25)
        guard !enabled.isEmpty else { return "" }
        return "Installed skills (call use_skill with the exact name to load one before doing a task it covers):\n"
            + enabled.map { "- \($0.id): \($0.description.prefix(200))" }.joined(separator:"\n")
    }
    var modelTools:[[String:Any]] { Array(toolDefinitions.prefix(Self.modelToolBudget)) }
    func pluginDirectoriesForClaude() -> [String] { library.claudePluginDirectories() }
    func mcpConfigForClaude() -> String? { library.claudeMCPConfig() }
}
