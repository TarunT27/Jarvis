import SwiftUI
import JarvisCore

@main struct JarvisApp:App {
    @State private var assistant=Assistant()

    init() {
        JarvisTypography.register()
    }

    var body:some Scene {
        WindowGroup("Jarvis",id:"main") {
            MainView(assistant:assistant)
                .frame(minWidth:850,minHeight:620)
                .environment(\.font, JarvisTypography.font(.regular, style: .body))
                .jarvisAppearance()
        }
            .defaultSize(width:1200,height:860)
            .commands {
                CommandGroup(replacing:.newItem) { Button("New Conversation") { assistant.newChat() }.keyboardShortcut("n") }
                JarvisNavigationCommands(assistant: assistant)
            }
        MenuBarExtra("Jarvis",systemImage:assistant.recording ? "mic.fill":"waveform.circle") {
            MenuContent(assistant:assistant)
        }
    }
}
struct MenuContent:View {
    let assistant:Assistant
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        VStack {
            Text(assistant.status)
            Button("Open Jarvis") { openWindow(id:"main");NSApp.activate(ignoringOtherApps:true) }
            Button("Stop Everything") { assistant.stop() }
            Divider()
            Button("Quit Jarvis") { assistant.shutdown();NSApp.terminate(nil) }
        }
        .environment(\.font, JarvisTypography.font(.regular, style: .body))
    }
}
struct MainView:View {
    @Bindable var assistant:Assistant
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarQuery=""
    @State private var showingNewProject=false
    @State private var showingAccountMenu=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection

    private var sidebarConversations:[ConversationSummary] {
        let query=sidebarQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        let filtered=query.isEmpty ? assistant.conversations : assistant.conversations.filter{$0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)}
        return Array(filtered.prefix(query.isEmpty ? 6 : 20))
    }
    private var sidebarProjects:[JarvisProject] {
        let query=sidebarQuery.trimmingCharacters(in:.whitespacesAndNewlines)
        return query.isEmpty ? assistant.projects : assistant.projects.filter{$0.name.localizedCaseInsensitiveContains(query)}
    }

    var body:some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .padding(.horizontal,14)
                .background(JarvisTheme.sidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 300)
        } detail: {
            VStack(spacing:0) {
                if let error=assistant.error {
                    HStack(alignment:.top) { Image(systemName:"exclamationmark.circle");Text(error).textSelection(.enabled);Spacer();Button { assistant.error=nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }
                        .font(JarvisTypography.font(.regular, style: .callout)).padding(14).background(JarvisTheme.error.opacity(0.12))
                        .transition(.move(edge:.top).combined(with:.opacity))
                }
                switch assistant.selectedPage {
                case "Overview":DashboardView(assistant:assistant)
                case "Chat directory":ChatDirectoryView(assistant:assistant) { showingNewProject=true }
                case "Notes & prompts":WorkspaceView(assistant:assistant)
                case "Memory":RecordView(assistant:assistant,kind:"memory",title:"Explicit memories",subtitle:"Lasting facts are saved only when you ask or approve.")
                case "Activity":RecordView(assistant:assistant,kind:"audit",title:"Action history",subtitle:"Minimal action metadata, retained for 30 days.")
                case "Connections":ConnectionsView(assistant:assistant)
                case "Settings":SettingsView(assistant:assistant)
                default:ChatView(assistant:assistant)
                }
            }
            .animation(JarvisMotion.settling(reduceMotion), value: assistant.error == nil)
            .background(JarvisTheme.canvas)
        }.navigationSplitViewStyle(.balanced)
        // Sidebar placement hoists the field above everything the sidebar's own
        // stack draws, so the first thing in the window was an empty search box
        // and the second was the product's name. The toolbar is where macOS puts
        // search for a list you are filtering.
        .searchable(text:$sidebarQuery,placement:.toolbar,prompt:"Search chats and projects")
        .tint(JarvisTheme.selection)
        .alert("Microphone Access Needed", isPresented:$assistant.microphoneAccessRequired) {
            Button("Open Microphone Settings") { assistant.openMicrophoneSettings() }
            Button("Not Now", role:.cancel) {}
        } message: {
            Text("Jarvis needs microphone access to listen. Enable Jarvis in System Settings → Privacy & Security → Microphone, then try again.")
        }
        .sheet(item:$assistant.proposal) { proposal in ApprovalView(proposal:proposal) { assistant.decide($0) }.interactiveDismissDisabled() }
        .sheet(isPresented:$showingNewProject) { NewProjectView { assistant.createProject(named:$0) } }
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:11) {
                JarvisMark().frame(width:30,height:30)
                Text("Jarvis").font(.system(size:19,weight:.semibold)).tracking(-0.2)
            }.padding(.top,18).padding(.bottom,16)
            Button { assistant.newChat() } label: {
                HStack(spacing:10) {
                    Image(systemName:"square.and.pencil").frame(width:16)
                    Text("New conversation")
                    Spacer(minLength:6)
                    Text("⌘N").font(.caption2).monospaced().foregroundStyle(JarvisTheme.tertiary)
                }
                .padding(.horizontal,11).padding(.vertical,7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(JarvisTheme.accent)
            .help("Start a new conversation (⌘N)")
            .accessibilityIdentifier("sidebar.new-conversation")
            navigation.padding(.top,8)
            List {
                Section("Recent") {
                    if sidebarConversations.isEmpty {
                        Text(sidebarQuery.isEmpty ? "No recent chats yet" : "No matching chats")
                            .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                    } else {
                        ForEach(sidebarConversations) { conversation in
                            Button { assistant.openConversation(conversation.id) } label: { RecentChatRow(conversation:conversation,compact:true) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open chat directory") { assistant.directoryProjectID=nil;assistant.selectedPage="Chat directory" }
                                    Menu("Move to project") {
                                        Button("No project") { assistant.assignConversation(conversation.id,to:nil) }
                                        ForEach(assistant.projects) { project in Button(project.name) { assistant.assignConversation(conversation.id,to:project.id) } }
                                    }
                                }
                        }
                        if sidebarQuery.isEmpty && assistant.conversations.count>sidebarConversations.count {
                            Button("View all chats",systemImage:"arrow.right") { assistant.selectedPage="Chat directory" }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Projects") {
                    ForEach(sidebarProjects) { project in
                        Button {
                            assistant.directoryProjectID=project.id;assistant.selectedPage="Chat directory"
                        } label: {
                            Label(project.name,systemImage:"folder").lineLimit(1)
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete project",role:.destructive) { assistant.deleteProject(project.id) }
                            }
                    }
                    Button("New project",systemImage:"folder.badge.plus") { showingNewProject=true }.buttonStyle(.borderless)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider().overlay(JarvisTheme.border)
            statusRow.padding(.vertical,10)
        }
    }

    /// One tinted capsule that travels between rows rather than vanishing here and
    /// reappearing there, so the move itself says which direction you went.
    private var navigation: some View {
        VStack(alignment:.leading,spacing:1) {
            ForEach(AppPage.allCases) { page in
                let selected = assistant.selectedPage == page.rawValue
                Button { assistant.selectedPage = page.rawValue } label: {
                    HStack(spacing:10) {
                        Image(systemName:page.symbol).frame(width:16)
                        Text(LocalizedStringKey(page.rawValue)).lineLimit(1)
                        Spacer(minLength:6)
                        if let label = page.shortcutLabel {
                            Text(label).font(.caption2).monospaced()
                                .foregroundStyle(selected ? JarvisTheme.tertiary : JarvisTheme.disabled)
                        }
                    }
                    .padding(.horizontal,11).padding(.vertical,7)
                    .contentShape(Rectangle())
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius:7,style:.continuous)
                                .fill(JarvisTheme.selection.opacity(0.24))
                                .matchedGeometryEffect(id:"navigation",in:navigationSelection)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? JarvisTheme.text : JarvisTheme.secondary)
                .accessibilityLabel(Text(LocalizedStringKey(page.rawValue)))
                .accessibilityAddTraits(selected ? [.isButton,.isSelected] : .isButton)
                .accessibilityIdentifier("sidebar." + page.rawValue.lowercased())
            }
        }
        .animation(JarvisMotion.settling(reduceMotion), value: assistant.selectedPage)
    }

    /// The one place that answers "where is this running". The two-line privacy
    /// paragraph that used to sit here moved to Settings, where someone is asking.
    private var statusRow: some View {
        Button { showingAccountMenu.toggle() } label: {
            HStack(spacing:9) {
                Circle().fill(assistant.unlocked ? JarvisTheme.healthy : JarvisTheme.warning)
                    .frame(width:7,height:7)
                Text(assistant.unlocked ? "Local" : "Locked")
                    .font(JarvisTypography.font(.regular,style:.subheadline))
                Spacer(minLength:4)
                Image(systemName:"gearshape").font(.system(size:12)).foregroundStyle(JarvisTheme.secondary)
            }
            .padding(.horizontal,11).padding(.vertical,7)
            .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:7,style:.continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Everything runs on this Mac. Opens Settings and Activity.")
        .accessibilityLabel(assistant.unlocked ? "Jarvis is running locally" : "Jarvis is locked")
        .accessibilityHint("Opens Settings and Activity")
        .accessibilityIdentifier("sidebar.account-menu")
        .popover(isPresented:$showingAccountMenu,attachmentAnchor:.point(.bottomLeading),arrowEdge:.bottom) {
            SidebarStatusMenu(assistant:assistant) { showingAccountMenu=false }
        }
    }
}

private struct SidebarStatusMenu: View {
    @Bindable var assistant:Assistant
    let dismiss:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"lock.shield").font(.system(size:15)).foregroundStyle(JarvisTheme.healthy)
                VStack(alignment:.leading,spacing:2) {
                    Text("Everything runs on this Mac").font(JarvisTypography.font(.semibold,style:.subheadline))
                    Text("Audio, models and memory stay local.").font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                }
            }.padding(.bottom,12)
            Divider()
            Button { assistant.selectedPage="Settings";dismiss() } label: { Label("Settings",systemImage:"slider.horizontal.3").frame(maxWidth:.infinity,alignment:.leading) }
                .buttonStyle(.borderless).padding(.top,8).accessibilityIdentifier("account.settings")
            Button { assistant.selectedPage="Activity";dismiss() } label: { Label("Activity",systemImage:"checkmark.shield").frame(maxWidth:.infinity,alignment:.leading) }
                .buttonStyle(.borderless).padding(.top,8).accessibilityIdentifier("account.activity")
        }.padding(14).frame(width:260)
    }
}

/// User-facing copy for the one screen where a local assistant stops being local.
/// Every tool that reaches this sheet gets a sentence describing what will happen
/// and, when it leaves the machine, where it goes.
enum ApprovalCopy {
    /// Tools whose effect is a network request to a third party.
    static let outbound: [String:String] = [
        "send_email":"Google",
        "calendar_create":"Google Calendar",
        "calendar_update":"Google Calendar"
    ]
    /// Argument order, so the thing being acted on is read first.
    private static let order: [String:[String]] = [
        "send_email":["to","subject","body"],
        "calendar_create":["title","start","end","timezone","attendees"],
        "calendar_update":["id","title","start","end","timezone","attendees"],
        "create_reminder":["title","due"],
        "save_memory":["text"],
        "move_file":["source","destination"],
        "trash_file":["path"]
    ]
    /// Values that are identifiers, paths or timestamps read character by
    /// character. They are shown exactly as they will be used, never reformatted.
    private static let literal: Set<String> = ["to","attendees","path","source","destination","id","start","end","timezone","due","bundle_id"]
    private static let labels: [String:String] = ["to":"To","id":"Event ID","due":"Due","timezone":"Time zone"]

    static func headline(_ call: ToolCall) -> String {
        let value = { (key: String) in call.arguments[key] ?? "" }
        switch call.name {
        case "send_email": return "Send an email to \(value("to"))"
        case "calendar_create": return "Create the event “\(value("title"))”"
        case "calendar_update": return "Change the event “\(value("title"))”"
        case "create_reminder": return "Create a reminder: \(value("title"))"
        case "save_memory": return "Remember this from now on"
        case "move_file": return "Move \(URL(fileURLWithPath:value("source")).lastPathComponent)"
        case "trash_file": return "Move \(URL(fileURLWithPath:value("path")).lastPathComponent) to the Trash"
        default: return call.name.replacingOccurrences(of:"_",with:" ").capitalized
        }
    }
    static func fields(_ call: ToolCall) -> [String] {
        let present = call.arguments.keys.filter { !(call.arguments[$0] ?? "").isEmpty }
        guard let preferred = order[call.name] else { return present.sorted() }
        return preferred.filter(present.contains) + present.filter { !preferred.contains($0) }.sorted()
    }
    static func label(_ key: String) -> String { labels[key] ?? key.replacingOccurrences(of:"_",with:" ").capitalized }
    static func isLiteral(_ key: String) -> Bool { literal.contains(key) }
}

struct ApprovalView:View {
    let proposal:ActionProposal
    let decide:(Bool)->Void
    @FocusState private var focus:Field?
    private enum Field { case decline }

    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let remaining=max(0,proposal.expires.timeIntervalSince(context.date))
            sheet(remaining:remaining)
        }
    }

    private func sheet(remaining:TimeInterval) -> some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:9) {
                Image(systemName:"hand.raised.fill").font(.system(size:13))
                    .foregroundStyle(remaining>0 ? JarvisTheme.warning : JarvisTheme.error)
                Text("Waiting on you").font(.system(size:10,weight:.semibold)).tracking(1.4)
                    .foregroundStyle(remaining>0 ? JarvisTheme.warning : JarvisTheme.error)
                Spacer(minLength:8)
                // A deadline you can watch is the only honest way to show one.
                Text(remaining>0 ? "expires in \(countdown(remaining))" : "expired")
                    .font(.caption).monospacedDigit().foregroundStyle(JarvisTheme.tertiary)
                    .accessibilityLabel(remaining>0 ? "Expires in \(Int(remaining)) seconds" : "Approval expired")
            }
            .padding(.bottom,14)

            Text(ApprovalCopy.headline(proposal.call))
                .font(JarvisTypography.font(.semibold,style:.title2))
                .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                .padding(.bottom,8)

            destination.padding(.bottom,22)

            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    ForEach(Array(ApprovalCopy.fields(proposal.call).enumerated()),id:\.element) { index,key in
                        if index>0 { Divider().overlay(JarvisTheme.border).padding(.horizontal,16) }
                        HStack(alignment:.top,spacing:14) {
                            Text(ApprovalCopy.label(key))
                                .font(.system(size:10,weight:.semibold)).tracking(0.4).textCase(.uppercase)
                                .foregroundStyle(JarvisTheme.tertiary)
                                .frame(width:74,alignment:.leading).padding(.top,2)
                            Text(proposal.call.arguments[key] ?? "")
                                .font(ApprovalCopy.isLiteral(key) ? .system(size:12,design:.monospaced) : .system(size:12))
                                .foregroundStyle(ApprovalCopy.isLiteral(key) ? JarvisTheme.text : JarvisTheme.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading)
                        }.padding(.horizontal,16).padding(.vertical,12)
                    }
                }
            }
            .frame(maxHeight:320)
            .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:11,style:.continuous))
            .padding(.bottom,18)

            Text("Applies once, to exactly these values. Approving does not grant Jarvis standing access.")
                .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                .padding(.bottom,22)

            HStack {
                Button("Decline",role:.cancel) { decide(false) }
                    .controlSize(.large)
                    .focused($focus,equals:.decline)
                Spacer()
                // Antique bronze, not pearl: this is the primary action, but it
                // should not be the brightest thing on the screen. Drawn rather
                // than tinted, because .borderedProminent ignores a tint here and
                // renders the label unreadable against its own fill.
                Button { decide(true) } label: {
                    Text(approveTitle)
                        .font(.system(size:13,weight:.medium))
                        .padding(.horizontal,18).padding(.vertical,9)
                        .foregroundStyle(remaining>0 ? JarvisTheme.buttonInk : JarvisTheme.disabled)
                        .background(remaining>0 ? JarvisTheme.primaryFill : JarvisTheme.surface,
                                    in:RoundedRectangle(cornerRadius:8,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:8,style:.continuous)
                            .strokeBorder(remaining>0 ? .clear : JarvisTheme.border,lineWidth:1))
                }
                .buttonStyle(.plain)
                .disabled(remaining<=0)
                .accessibilityIdentifier("approval.approve")
            }
        }
        .padding(28).frame(width:520)
        .foregroundStyle(JarvisTheme.text)
        .tint(JarvisTheme.selection)
        // The sheet is a raised surface, not another sheet of canvas.
        .background(JarvisTheme.elevated)
        // Return must not be able to send an email. Nothing claims the default
        // action; the focus ring starts on Decline.
        .defaultFocus($focus,.decline)
    }

    private var approveTitle:String {
        switch proposal.call.name {
        case "send_email": "Approve and send"
        case "trash_file": "Approve and move to Trash"
        case "save_memory": "Approve and remember"
        default: "Approve and execute"
        }
    }

    @ViewBuilder
    private var destination:some View {
        if let service=ApprovalCopy.outbound[proposal.call.name] {
            Label("This leaves your Mac. It goes to \(service).",systemImage:"globe")
                .font(.callout).foregroundStyle(JarvisTheme.recording)
        } else {
            Label("Stays on this Mac.",systemImage:"lock")
                .font(.callout).foregroundStyle(JarvisTheme.healthy)
        }
    }

    private func countdown(_ remaining:TimeInterval) -> String {
        let seconds=Int(remaining.rounded())
        return String(format:"%d:%02d",seconds/60,seconds%60)
    }
}

struct RecordView:View {
    @Bindable var assistant:Assistant
    let kind:String;let title:String;let subtitle:String
    @State private var newMemory=""
    @State private var clear=false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text(title).font(JarvisTypography.font(.semibold, style: .title));Spacer();Button("Refresh") { Task { await assistant.loadRecords(kind) } };Button("Export") { assistant.exportRecords() } }
            Text(subtitle).foregroundStyle(JarvisTheme.secondary)
            if kind=="memory" { HStack { TextField("A preference to remember",text:$newMemory);Button("Save") { let text=newMemory;newMemory="";Task { await assistant.command("memory",value:text);await assistant.loadRecords(kind) } }.disabled(newMemory.isEmpty) } }
            List {
                if assistant.records.isEmpty { Text("Nothing saved yet.").foregroundStyle(JarvisTheme.secondary) }
                ForEach(assistant.records,id:\.self) { row in
                    HStack(alignment:.top) { Text(row["body"] ?? "").textSelection(.enabled);Spacer();if kind != "audit" { Button("Delete",role:.destructive) { Task { await assistant.command("delete_record",value:row["id"]);await assistant.loadRecords(kind) } } } }
                        .padding(.vertical,8)
                }
            }
            if kind != "audit" { Button("Clear all \(kind)",role:.destructive) { clear=true }.confirmationDialog("Delete all \(kind) records?",isPresented:$clear) { Button("Delete all",role:.destructive) { Task { await assistant.command("clear",value:kind);await assistant.loadRecords(kind) } } } }
        }.padding(28).task(id:kind) { await assistant.loadRecords(kind) }
    }
}
struct ConnectionsView:View {
    @Bindable var assistant:Assistant
    @State private var braveKey=""
    var body:some View {
        Form {
            Section("Google · Gmail and Calendar") {
                Text(assistant.googleConnected ? "Connected":"Not connected").foregroundStyle(assistant.googleConnected ? JarvisTheme.healthy:JarvisTheme.secondary)
                Text("Create a Desktop OAuth client in your Google Cloud project, enable Gmail and Calendar APIs, and import its JSON. Your existing Codex connections are separate.").font(JarvisTypography.font(.regular, style: .callout))
                Button("Import Google client JSON…") { assistant.importGoogle() }
                HStack { Button("Connect read-only") { Task { await assistant.command("google_connect",value:"read") } };Button("Enable sending and event changes") { Task { await assistant.command("google_connect",value:"write") } } }
                Button("Disconnect Google",role:.destructive) { Task { await assistant.command("disconnect_google") } }.disabled(!assistant.googleConnected)
                Link("Google setup documentation",destination:URL(string:"https://developers.google.com/workspace/gmail/api/quickstart/python")!)
            }
            Section("Web search · Brave") {
                Text(assistant.braveConnected ? "API key saved in Keychain":"Add your own Brave Search API key. Provider charges may apply.")
                SecureField("Brave Search API key",text:$braveKey)
                Button("Save search key") { let key=braveKey;braveKey="";Task { await assistant.command("brave_key",value:key) } }.disabled(braveKey.isEmpty)
                Button("Disconnect search",role:.destructive) { Task { await assistant.command("disconnect_brave") } }
                Link("Get a Brave Search API key",destination:URL(string:"https://api-dashboard.search.brave.com/")!)
            }
            Section("Privacy boundary") { Text("AI inference never uses these services. Search sends a query to Brave; Gmail and Calendar requests go to Google. Private content is not automatically included in web searches.") }
        }.formStyle(.grouped).scrollContentBackground(.hidden).background(JarvisTheme.canvas).navigationTitle("Connections")
    }
}
struct SettingsView:View {
    @Bindable var assistant:Assistant
    @State private var clearHistory=false
    var body:some View {
        Form {
            Section("Local intelligence") {
                Label("Everything runs on this Mac",systemImage:"lock.shield").foregroundStyle(JarvisTheme.healthy)
                Text("Speech recognition, the language model, spoken replies and saved memory all run and stay on this machine. Gmail, Calendar and web search are the only features that send anything outward, and each one asks first.").font(JarvisTypography.font(.regular, style: .callout)).foregroundStyle(JarvisTheme.secondary)
            }
            Section("Voice and performance") {
                Picker("Recognition language",selection:$assistant.language) { Text("English / Telugu · detect").tag("auto");Text("English").tag("en");Text("Telugu").tag("te") }
                Picker("Voice shortcut",selection:$assistant.shortcutOption) { Text("Control–Option–Space").tag(0);Text("Command–Option–Space").tag(1) }.onChange(of:assistant.shortcutOption) { _,_ in assistant.changeShortcut() }
                Toggle("Keep the language model warm",isOn:$assistant.keepWarm)
                Text("Default: unload after five idle minutes. Keeping it warm uses memory between conversations.").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
                Toggle("Deep mode · Qwen3.8 27B",isOn:$assistant.deep).disabled(!assistant.models.contains(Configuration.deep))
                Text("Deep mode is disabled until its model is installed and validated. Everyday mode uses an 8K context window.").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
            }
            Section("Approved folders") {
                ForEach(assistant.folders,id:\.self) { path in HStack { Text(path).font(JarvisTypography.font(.regular, style: .caption)).textSelection(.enabled);Spacer();Button("Revoke") { Task { await assistant.command("remove_folder",value:path) } } } }
                Button("Choose a folder…") { assistant.chooseFolder() }
                Text("Only PDF, Markdown, and text files in these folders can be read. No whole-disk indexing.").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
            }
            Section("Approved applications") {
                ForEach(assistant.apps,id:\.self) { app in HStack { Text(app).font(JarvisTypography.font(.regular, style: .caption));Spacer();Button("Revoke") { Task { await assistant.command("remove_app",value:app) } } } }
                Button("Allow an application…") { assistant.chooseApp() }
            }
            Section("History") {
                Text("Encrypted local history is retained for 30 days. Explicit memories remain until you delete them.")
                Button("Clear conversation history",role:.destructive) { clearHistory=true }.confirmationDialog("Delete saved conversation history?",isPresented:$clearHistory) { Button("Delete history",role:.destructive) { assistant.clearChatHistory() } }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).background(JarvisTheme.canvas).navigationTitle("Settings")
    }
}
