import SwiftUI
import JarvisCore

@main struct JarvisApp:App {
    @State private var assistant=Assistant()
    var body:some Scene {
        WindowGroup("Jarvis",id:"main") { MainView(assistant:assistant).frame(minWidth:850,minHeight:620) }
            .defaultSize(width:1040,height:740)
            .commands { CommandGroup(replacing:.newItem) { Button("New Conversation") { assistant.newChat() }.keyboardShortcut("n") } }
        MenuBarExtra("Jarvis",systemImage:assistant.recording ? "mic.fill":"waveform.circle") {
            MenuContent(assistant:assistant)
        }
    }
}
struct MenuContent:View {
    let assistant:Assistant
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        Text(assistant.status)
        Button("Open Jarvis") { openWindow(id:"main");NSApp.activate(ignoringOtherApps:true) }
        Button("Stop Everything") { assistant.stop() }
        Divider()
        Button("Quit Jarvis") { assistant.shutdown();NSApp.terminate(nil) }
    }
}
struct MainView:View {
    @Bindable var assistant:Assistant
    private let pages=["Chat","Memory","Drafts","Connections","Settings","Activity"]
    private let icons=["Chat":"bubble.left.and.bubble.right","Memory":"brain","Drafts":"doc.text","Connections":"point.3.connected.trianglepath.dotted","Settings":"slider.horizontal.3","Activity":"checkmark.shield"]
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:24) {
                HStack(spacing:12) {
                    Image(systemName:"waveform.circle.fill").font(.system(size:32)).foregroundStyle(.teal)
                    VStack(alignment:.leading,spacing:2) { Text("JARVIS").font(.system(size:18,weight:.semibold,design:.rounded)).tracking(2);Text("Your Mac. Your assistant.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top,18)
                List(pages,id:\.self,selection:$assistant.selectedPage) { page in Label(page,systemImage:icons[page]!).tag(page) }.listStyle(.sidebar)
                VStack(alignment:.leading,spacing:8) {
                    Label("Local intelligence",systemImage:"lock.shield").font(.caption.weight(.medium))
                    Text("Audio, models, and memory stay on your Mac.").font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom,20)
            }.padding(.horizontal,14).navigationSplitViewColumnWidth(210)
        } detail: {
            VStack(spacing:0) {
                if let error=assistant.error {
                    HStack(alignment:.top) { Image(systemName:"exclamationmark.circle");Text(error).textSelection(.enabled);Spacer();Button { assistant.error=nil } label:{ Image(systemName:"xmark") }.buttonStyle(.plain) }
                        .font(.callout).padding(14).background(.orange.opacity(0.12))
                }
                switch assistant.selectedPage {
                case "Memory":RecordView(assistant:assistant,kind:"memory",title:"Explicit memories",subtitle:"Lasting facts are saved only when you ask or approve.")
                case "Drafts":RecordView(assistant:assistant,kind:"draft",title:"Local drafts",subtitle:"These drafts have not been sent.")
                case "Activity":RecordView(assistant:assistant,kind:"audit",title:"Action history",subtitle:"Minimal action metadata, retained for 30 days.")
                case "Connections":ConnectionsView(assistant:assistant)
                case "Settings":SettingsView(assistant:assistant)
                default:ChatView(assistant:assistant)
                }
            }.background(Color(nsColor:.windowBackgroundColor))
        }.tint(.teal)
        .sheet(item:$assistant.proposal) { proposal in ApprovalView(proposal:proposal) { assistant.decide($0) }.interactiveDismissDisabled() }
    }
}
struct ChatView:View {
    @Bindable var assistant:Assistant
    var body:some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:4) { Text("A little help, close at hand.").font(.title2.weight(.medium));Text(assistant.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button { assistant.newChat() } label:{ Image(systemName:"square.and.pencil") }.help("New conversation")
                Button("Stop",systemImage:"stop.circle") { assistant.stop() }.keyboardShortcut(.escape,modifiers:[])
            }.padding(24)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:22) {
                        if assistant.messages.isEmpty {
                            VStack(alignment:.leading,spacing:20) {
                                Image(systemName:"waveform.path").font(.system(size:42,weight:.ultraLight)).foregroundStyle(.teal).padding(.bottom,10)
                                Text("Hello. What’s on your mind?").font(.system(size:29,weight:.light))
                                Text("Type below, or hold Control–Option–Space to talk.\nEnglish and Telugu in. English voice out.").font(.body).foregroundStyle(.secondary).lineSpacing(5)
                                ForEach(["Help me plan my day","Find a document in my approved folders","Remember that I prefer concise replies"],id:\.self) { suggestion in
                                    Button { assistant.input=suggestion } label:{ HStack { Text(suggestion);Spacer();Image(systemName:"arrow.up.left") }.padding(12) }.buttonStyle(.bordered)
                                }
                            }.padding(.vertical,36)
                        }
                        ForEach(assistant.messages) { message in
                            VStack(alignment:.leading,spacing:7) {
                                Text(message.role=="user" ? "YOU":"JARVIS").font(.system(size:10,weight:.bold)).tracking(1.5).foregroundStyle(message.role=="user" ? Color.secondary:Color.teal)
                                Text(message.content.isEmpty ? "…":message.content).textSelection(.enabled).font(.system(size:15)).lineSpacing(5).frame(maxWidth:.infinity,alignment:.leading)
                            }.padding(16).background(message.role=="user" ? Color.primary.opacity(0.035):Color.clear,in:RoundedRectangle(cornerRadius:14)).id(message.id)
                        }
                        Color.clear.frame(height:1).id("bottom")
                    }.padding(.horizontal,28).padding(.bottom,20)
                }.onChange(of:assistant.messages.last?.content) { _,_ in proxy.scrollTo("bottom",anchor:.bottom) }
            }
            VStack(spacing:12) {
                if assistant.screenImage != nil { HStack { Label("Screen attached · stays local",systemImage:"display");Spacer();Button("Remove") { assistant.screenImage=nil } }.font(.caption) }
                HStack(alignment:.bottom,spacing:12) {
                    TextField("Ask Jarvis…",text:$assistant.input,axis:.vertical).lineLimit(1...5).textFieldStyle(.plain).padding(14).onSubmit { assistant.send() }
                    Button { assistant.send() } label:{ Image(systemName:"arrow.up").font(.headline).frame(width:26,height:30) }.buttonStyle(.borderedProminent).disabled(assistant.busy || assistant.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).padding(7)
                }.background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:16))
                HStack(spacing:16) {
                    Text(assistant.recording ? "Release to send":"Hold to talk").font(.caption.weight(.medium)).padding(.horizontal,10).padding(.vertical,6).background(assistant.recording ? Color.red.opacity(0.2):Color.teal.opacity(0.1),in:Capsule())
                        .onLongPressGesture(minimumDuration:0.01,pressing:{ down in if down { assistant.press() } else { assistant.release() } },perform:{})
                        .accessibilityLabel("Hold to record voice")
                    Button { Task { await assistant.captureScreen() } } label:{ Image(systemName:"display") }.buttonStyle(.plain).help("Attach current screen")
                    Toggle("Voice",isOn:Binding(get:{!assistant.muted},set:{assistant.muted = !$0;if assistant.muted { assistant.stop() }})).toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Text("Qwen3.5 · 9B").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
    }
}
struct ApprovalView:View {
    let proposal:ActionProposal
    let decide:(Bool)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Label("Review this action",systemImage:"hand.raised.fill").font(.title2)
            Text(proposal.call.name.replacingOccurrences(of:"_",with:" ").capitalized).font(.headline)
            ScrollView { VStack(alignment:.leading,spacing:14) { ForEach(proposal.call.arguments.keys.sorted(),id:\.self) { key in
                VStack(alignment:.leading,spacing:4) { Text(key.capitalized).font(.caption).foregroundStyle(.secondary);Text(proposal.call.arguments[key]!.isEmpty ? "None":proposal.call.arguments[key]!).textSelection(.enabled) }
            } } }.frame(maxHeight:350)
            Text("Applies once to exactly these values. Expires in two minutes.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Decline",role:.cancel) { decide(false) };Spacer();Button("Approve and execute") { decide(true) }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width:520)
    }
}
struct RecordView:View {
    @Bindable var assistant:Assistant
    let kind:String;let title:String;let subtitle:String
    @State private var newMemory=""
    @State private var clear=false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text(title).font(.title);Spacer();Button("Refresh") { Task { await assistant.loadRecords(kind) } };Button("Export") { assistant.exportRecords() } }
            Text(subtitle).foregroundStyle(.secondary)
            if kind=="memory" { HStack { TextField("A preference to remember",text:$newMemory);Button("Save") { let text=newMemory;newMemory="";Task { await assistant.command("memory",value:text);await assistant.loadRecords(kind) } }.disabled(newMemory.isEmpty) } }
            List {
                if assistant.records.isEmpty { Text("Nothing saved yet.").foregroundStyle(.secondary) }
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
                Text(assistant.googleConnected ? "Connected":"Not connected").foregroundStyle(assistant.googleConnected ? Color.green:Color.secondary)
                Text("Create a Desktop OAuth client in your Google Cloud project, enable Gmail and Calendar APIs, and import its JSON. Your existing Codex connections are separate.").font(.callout)
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
        }.formStyle(.grouped).navigationTitle("Connections")
    }
}
struct SettingsView:View {
    @Bindable var assistant:Assistant
    @State private var clearHistory=false
    var body:some View {
        Form {
            Section("Voice and performance") {
                Picker("Recognition language",selection:$assistant.language) { Text("English / Telugu · detect").tag("auto");Text("English").tag("en");Text("Telugu").tag("te") }
                Picker("Push-to-talk shortcut",selection:$assistant.shortcutOption) { Text("Control–Option–Space").tag(0);Text("Command–Option–Space").tag(1) }.onChange(of:assistant.shortcutOption) { _,_ in assistant.changeShortcut() }
                Toggle("Keep the language model warm",isOn:$assistant.keepWarm)
                Text("Default: unload after five idle minutes. Keeping it warm uses memory between conversations.").font(.caption).foregroundStyle(.secondary)
                Toggle("Deep mode · Qwen3.8 27B",isOn:$assistant.deep).disabled(!assistant.models.contains(Configuration.deep))
                Text("Deep mode is disabled until its model is installed and validated. Everyday mode uses an 8K context window.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Approved folders") {
                ForEach(assistant.folders,id:\.self) { path in HStack { Text(path).font(.caption).textSelection(.enabled);Spacer();Button("Revoke") { Task { await assistant.command("remove_folder",value:path) } } } }
                Button("Choose a folder…") { assistant.chooseFolder() }
                Text("Only PDF, Markdown, and text files in these folders can be read. No whole-disk indexing.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Approved applications") {
                ForEach(assistant.apps,id:\.self) { app in HStack { Text(app).font(.caption);Spacer();Button("Revoke") { Task { await assistant.command("remove_app",value:app) } } } }
                Button("Allow an application…") { assistant.chooseApp() }
            }
            Section("History") {
                Text("Encrypted local history is retained for 30 days. Explicit memories remain until you delete them.")
                Button("Clear conversation history",role:.destructive) { clearHistory=true }.confirmationDialog("Delete saved conversation history?",isPresented:$clearHistory) { Button("Delete history",role:.destructive) { assistant.newChat();Task { await assistant.command("clear",value:"chat") } } }
            }
        }.formStyle(.grouped).navigationTitle("Settings")
    }
}
