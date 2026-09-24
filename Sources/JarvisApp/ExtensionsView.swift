import SwiftUI
import AppKit
import JarvisCore

struct ExtensionsView:View {
    @Bindable var assistant:Assistant
    @State private var tab="Claude"
    @State private var sheet:Sheet?
    private enum Sheet:String,Identifiable { case skill,server,git; var id:String { rawValue } }
    private enum Removal:Identifiable {
        case skill(Skill),server(String),plugin(Plugin)
        var id:String { switch self { case .skill(let s): "s:"+s.id; case .server(let id): "m:"+id; case .plugin(let p): "p:"+p.name } }
        var title:String { switch self { case .skill(let s): "Remove the skill “\(s.name)”?"; case .server(let id): "Remove the MCP server “\(id)”?"; case .plugin(let p): "Remove the plugin “\(p.name)”?" } }
    }
    @State private var confirmRemove:Removal?
    private var store:ExtensionStore { assistant.extensions }

    var body:some View {
        Form {
            Section {
                Picker("Show",selection:$tab) { ForEach(["Claude","Skills","MCP servers","Plugins"],id:\.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of:tab) { _,_ in store.message=nil }
                if let message=store.message {
                    Label(message,systemImage:message.contains("failed") ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout).foregroundStyle(message.contains("failed") ? JarvisTheme.warning : JarvisTheme.healthy).textSelection(.enabled)
                }
            }
            switch tab {
            case "Skills": skills
            case "MCP servers": servers
            case "Plugins": plugins
            default: claude
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(JarvisTheme.canvas).navigationTitle("Extensions")
        .disabled(store.working)
        .overlay(alignment:.top) { if store.working { ProgressView().controlSize(.small).padding(8) } }
        .task { await store.refresh();assistant.claudeProjects=assistant.claudeProjectStore.all() }
        .confirmationDialog(confirmRemove?.title ?? "",isPresented:Binding(get:{ confirmRemove != nil },set:{ if !$0 { confirmRemove=nil } }),titleVisibility:.visible) {
            Button("Remove",role:.destructive) {
                switch confirmRemove { case .skill(let s): store.remove(s); case .server(let id): store.removeServer(id); case .plugin(let p): store.remove(p); case nil: break }
                confirmRemove=nil
            }
        } message: { Text("Its files are deleted from Jarvis's extensions folder.") }
        .sheet(item:$sheet) { which in
            switch which {
            case .skill: NewSkillSheet { store.createSkill(name:$0,description:$1,instructions:$2) }
            case .server: AddServerSheet { store.addServers(json:$0) }
            case .git: GitPluginSheet { store.installPlugin(git:$0) }
            }
        }
    }

    // MARK: Claude

    @ViewBuilder private var claude:some View {
        Section("Claude hand-off") {
            if let binary=ClaudeCLI.locate() {
                Label("Ready · uses the Claude Code bundled with your Claude app",systemImage:"checkmark.seal.fill").foregroundStyle(JarvisTheme.healthy)
                Text(binary.path).font(.caption).foregroundStyle(JarvisTheme.tertiary).textSelection(.enabled)
            } else {
                Label("Install the Claude app and sign in to hand tasks to Claude.",systemImage:"exclamationmark.circle").foregroundStyle(JarvisTheme.warning)
            }
            Text("Ask for Claude in chat (“use Claude to…”), or press ⌘⇧↩ to send what you typed. You always see and can edit the prompt, pick the model and effort, and choose where it may work before anything leaves this Mac.")
                .font(.callout).foregroundStyle(JarvisTheme.secondary)
            Toggle("Give Claude my enabled skills, plugins and MCP servers",isOn:Binding(get:{ store.state.shareWithClaude },set:{ store.setShareWithClaude($0) }))
        }
        Section {
            if assistant.claudeProjects.isEmpty {
                Text("No projects yet. Say “make a new project called Weather” when you ask Claude to build something, or add a folder you already have.")
                    .font(.callout).foregroundStyle(JarvisTheme.secondary)
            }
            ForEach(assistant.claudeProjects) { project in
                HStack {
                    VStack(alignment:.leading,spacing:2) {
                        Text(project.name).font(JarvisTypography.font(.medium,style:.body))
                        Text(project.path+(project.sessionID == nil ? "" : " · has a Claude session to continue")).font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show") { store.reveal(URL(fileURLWithPath:project.path)) }
                    Button("Forget") { assistant.claudeProjectStore.remove(project.name);assistant.claudeProjects=assistant.claudeProjectStore.all() }
                        .help("Removes it from Jarvis. The folder and its files are left untouched.")
                }
            }
            HStack {
                Button("Add a folder you already have…") { addExistingProject() }
                Button("Open Jarvis Builds") {
                    try? FileManager.default.createDirectory(at:assistant.claudeProjectStore.buildsRoot,withIntermediateDirectories:true)
                    NSWorkspace.shared.open(assistant.claudeProjectStore.buildsRoot)
                }
            }
        } header: { Text("Projects") } footer: {
            Text("Claude can edit files and run commands only inside a project's folder; the macOS sandbox blocks writes anywhere else.").font(.caption)
        }
    }

    private func addExistingProject() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="Add project"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let name=String(url.lastPathComponent.map { $0.isLetter || $0.isNumber || " _.-".contains($0) ? $0 : "-" }.prefix(60))
        do { try assistant.claudeProjectStore.add(name:name,folder:url);assistant.claudeProjects=assistant.claudeProjectStore.all();store.message="Added project “\(name)”." }
        catch { store.message="Adding the project failed: \(error.localizedDescription)" }
    }

    // MARK: Skills

    @ViewBuilder private var skills:some View {
        Section {
            HStack {
                Button("New skill…") { sheet = .skill }
                Button("Import from Claude") { store.importClaudeSkills() }
                    .disabled(!FileManager.default.fileExists(atPath:store.claudeSkillsFolder.path))
                    .help("Copies the skills in ~/.claude/skills")
                Button("Import folder or .zip…") { if let url=pick(files:true) { store.importSkills(from:url) } }
            }
        } footer: {
            Text("Skills are instructions in Claude's SKILL.md format. Jarvis sees each one's name and description and loads the rest when a task needs it.").font(.caption)
        }
        Section("Installed skills") {
            if store.skills.isEmpty { Text("None yet.").foregroundStyle(JarvisTheme.secondary) }
            ForEach(store.skills) { skill in
                HStack(alignment:.top) {
                    Toggle("",isOn:Binding(get:{ !store.state.disabledSkills.contains(skill.id) },set:{ store.setSkill(skill,enabled:$0) })).labelsHidden()
                    VStack(alignment:.leading,spacing:2) {
                        HStack(spacing:6) {
                            Text(skill.name).font(JarvisTypography.font(.medium,style:.body))
                            if let plugin=skill.plugin { Badge(text:plugin) }
                        }
                        Text(skill.description).font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Show") { store.reveal(skill.folder.appendingPathComponent("SKILL.md")) }
                    if skill.plugin == nil { Button("Remove…",role:.destructive) { confirmRemove = .skill(skill) } }
                }
            }
        }
    }

    // MARK: MCP

    @ViewBuilder private var servers:some View {
        Section {
            HStack {
                Button("Add server…") { sheet = .server }
                Button("Import from Claude Desktop") { store.importClaudeDesktopServers() }
                Button("Restart all") { Task { await store.refresh(restartServers:true) } }
            }
        } footer: {
            Text("MCP servers are programs that run on your Mac with your permissions, or services Jarvis contacts. Add only ones you trust. Every tool call asks you first unless you choose Always allow for that tool.").font(.caption)
        }
        if store.toolDefinitions.count > ExtensionStore.modelToolBudget {
            Section { Label("\(store.toolDefinitions.count) MCP tools are running; the local model is offered the first \(ExtensionStore.modelToolBudget). Switch off servers you don't need for better tool choices.",systemImage:"exclamationmark.triangle").foregroundStyle(JarvisTheme.warning) }
        }
        Section("Servers") {
            if store.servers.isEmpty { Text("None yet.").foregroundStyle(JarvisTheme.secondary) }
            ForEach(store.servers) { server in
                DisclosureGroup {
                    if server.tools.isEmpty { Text(server.enabled ? "No tools reported." : "Switched off.").font(.caption).foregroundStyle(JarvisTheme.secondary) }
                    if server.status.hasPrefix("Failed") { Text(server.status).font(.caption).foregroundStyle(JarvisTheme.error).textSelection(.enabled) }
                    ForEach(server.tools) { tool in
                        HStack(alignment:.top) {
                            VStack(alignment:.leading,spacing:2) {
                                Text(tool.name).font(.callout.monospaced())
                                if !tool.description.isEmpty { Text(tool.description).font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(2) }
                            }
                            Spacer()
                            Toggle("Always allow",isOn:Binding(get:{ tool.always },set:{ store.setAlways(tool.key,$0) })).font(.caption)
                        }
                    }
                    // Kept out of the row's label: a disclosure row forwards its press to
                    // the first button in its label, which removed servers on expand.
                    if server.editable {
                        HStack { Spacer();Button("Remove server…",role:.destructive) { confirmRemove = .server(server.id) } }
                    }
                } label: {
                    HStack {
                        Circle().fill(color(server.status)).frame(width:8,height:8)
                        Text(server.id).font(JarvisTypography.font(.medium,style:.body))
                        if let plugin=server.plugin { Badge(text:plugin) }
                        Text(server.status).font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Toggle("",isOn:Binding(get:{ server.enabled },set:{ store.setServer(server.id,enabled:$0) })).labelsHidden()
                    }
                }
            }
        }
    }
    private func color(_ status:String) -> Color {
        status.hasPrefix("Ready") ? JarvisTheme.healthy : status.hasPrefix("Failed") ? JarvisTheme.error : status == "Off" ? JarvisTheme.disabled : JarvisTheme.warning
    }

    // MARK: Plugins

    @ViewBuilder private var plugins:some View {
        Section {
            HStack {
                Button("Install from folder or .zip…") { if let url=pick(files:true) { store.installPlugin(from:url) } }
                Button("Install from Git…") { sheet = .git }
            }
        } footer: {
            Text("Plugins use the Claude Code layout: .claude-plugin/plugin.json with skills, MCP servers (.mcp.json), commands and agents. Jarvis uses the skills and servers; Claude hand-offs get the whole plugin.").font(.caption)
        }
        Section("Installed plugins") {
            if store.plugins.isEmpty { Text("None yet.").foregroundStyle(JarvisTheme.secondary) }
            ForEach(store.plugins) { plugin in
                HStack(alignment:.top) {
                    Toggle("",isOn:Binding(get:{ !store.state.disabledPlugins.contains(plugin.name) },set:{ store.setPlugin(plugin,enabled:$0) })).labelsHidden()
                    VStack(alignment:.leading,spacing:2) {
                        Text(plugin.name+(plugin.version.isEmpty ? "" : "  \(plugin.version)")).font(JarvisTypography.font(.medium,style:.body))
                        if !plugin.description.isEmpty { Text(plugin.description).font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(2) }
                        Text("\(plugin.skillCount) skills · \(plugin.serverCount) MCP servers · \(plugin.commandCount) commands").font(.caption).foregroundStyle(JarvisTheme.tertiary)
                    }
                    Spacer()
                    Button("Show") { store.reveal(plugin.folder) }
                    Button("Remove…",role:.destructive) { confirmRemove = .plugin(plugin) }
                }
            }
        }
    }

    private func pick(files:Bool) -> URL? {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=files
        panel.allowedContentTypes=[.zip,.folder];panel.prompt="Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct Badge:View {
    let text:String
    var body:some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal,6).padding(.vertical,2)
            .background(JarvisTheme.selection.opacity(0.22),in:Capsule()).foregroundStyle(JarvisTheme.secondary)
    }
}

private struct NewSkillSheet:View {
    let create:(String,String,String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name="";@State private var description="";@State private var instructions=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("New skill").font(JarvisTypography.font(.semibold,style:.title2))
            TextField("Name, for example release-notes",text:$name).textFieldStyle(.roundedBorder)
            TextField("When to use it, for example: Write release notes from a list of changes",text:$description).textFieldStyle(.roundedBorder)
            Text("Instructions").font(.caption).foregroundStyle(JarvisTheme.secondary)
            TextEditor(text:$instructions).font(.body).frame(minHeight:180).scrollContentBackground(.hidden).padding(6)
                .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:8))
            HStack { Spacer();Button("Cancel",role:.cancel) { dismiss() }
                Button("Create") { create(name,description,instructions);dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in:.whitespaces).isEmpty || description.trimmingCharacters(in:.whitespaces).isEmpty) }
        }.padding(22).frame(width:520)
    }
}

private struct AddServerSheet:View {
    let add:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var json="""
    {
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"]
        }
      }
    }
    """
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Add MCP servers").font(JarvisTypography.font(.semibold,style:.title2))
            Text("Paste the same JSON you would give Claude Desktop. Local servers use command and args; remote ones use \"type\": \"http\" and a url, with any token under headers.")
                .font(.callout).foregroundStyle(JarvisTheme.secondary)
            TextEditor(text:$json).font(.system(.callout,design:.monospaced)).frame(minHeight:220).scrollContentBackground(.hidden).padding(6)
                .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:8))
            HStack { Spacer();Button("Cancel",role:.cancel) { dismiss() }
                Button("Add") { add(json);dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(22).frame(width:560)
    }
}

private struct GitPluginSheet:View {
    let install:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var address=""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Install a plugin from Git").font(JarvisTypography.font(.semibold,style:.title2))
            TextField("https://github.com/owner/plugin.git",text:$address).textFieldStyle(.roundedBorder)
            Text("Jarvis makes a shallow copy of the repository and installs it like a folder. Plugins can run programs; install only ones you trust.")
                .font(.caption).foregroundStyle(JarvisTheme.secondary)
            HStack { Spacer();Button("Cancel",role:.cancel) { dismiss() }
                Button("Install") { install(address);dismiss() }.buttonStyle(.borderedProminent).disabled(address.isEmpty) }
        }.padding(22).frame(width:520)
    }
}
