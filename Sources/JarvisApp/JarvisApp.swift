import SwiftUI
import JarvisCore

@main struct JarvisApp:App {
    @State private var assistant:Assistant

    init() {
        JarvisTypography.register()
        let assistant=Assistant()
        _assistant=State(initialValue:assistant)
        QuickBar.shared.install(assistant)
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
        MenuBarExtra("Jarvis",systemImage:assistant.recording ? "mic.fill":(assistant.wakeWordListening ? "waveform.circle.fill":"waveform.circle")) {
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
            Button(QuickBar.shared.shortcutAvailable ? "Ask Jarvis…  ⌥Space" : "Ask Jarvis…") { QuickBar.shared.show() }
            Button(assistant.conversationActive ? "End Spoken Conversation" : "Start Spoken Conversation") { assistant.toggleListening() }
            Toggle("Listen for “Hey Jarvis”",isOn:Binding(get:{ assistant.wakeWordEnabled },set:{ assistant.wakeWordEnabled=$0 }))
            if !assistant.timers.timers.isEmpty {
                Divider()
                Text("Timers · end if Jarvis quits")
                ForEach(assistant.timers.timers) { timer in
                    Button("Cancel \(timer.title) (ends \(timer.fires.formatted(date:.omitted,time:.shortened)))") { assistant.timers.cancel(timer.id) }
                }
            }
            Button("Stop Everything") { assistant.stop() }
            Divider()
            Button("Quit Jarvis") { assistant.shutdown();NSApp.terminate(nil) }
        }
        .environment(\.font, JarvisTypography.font(.regular, style: .body))
        .onAppear { QuickBar.shared.openMainWindow={ openWindow(id:"main") } }
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
    @Environment(\.openWindow) private var openWindow

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
        ZStack {
            windowContent
                // Together these are what .sheet gave for free: nothing behind the
                // approval can be clicked, tabbed into, or reached by VoiceOver - and
                // disabling also suppresses the Stop button's Escape shortcut, so
                // Escape means Decline and nothing else while this is up.
                .disabled(assistant.proposal != nil)
                .accessibilityHidden(assistant.proposal != nil)
            if let proposal=assistant.proposal { approvalOverlay(proposal) }
        }
        .animation(JarvisMotion.settling(reduceMotion), value: assistant.proposal?.id)
        .onAppear { QuickBar.shared.openMainWindow={ openWindow(id:"main") } }
    }

    /// The approval grows out of the conversation it interrupted rather than sliding in
    /// from the window edge, because the thing it is asking about is behind it.
    private func approvalOverlay(_ proposal:ActionProposal) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.38))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // Swallows the click. There is deliberately no dismiss-by-clicking-away:
                // the only ways out are Decline and Approve.
                .onTapGesture {}
                .transition(.opacity)
                .accessibilityHidden(true)
            ApprovalView(proposal:proposal, computerContext:proposal.call.name.hasPrefix("computer_") ? assistant.computerObservation : nil) { assistant.decide($0) }
                .transition(reduceMotion ? .opacity
                    : .scale(scale:0.94,anchor:.bottom)
                        .combined(with:.offset(y:14))
                        .combined(with:.opacity))
        }
        .accessibilityElement(children:.contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Review this action")
    }

    private var windowContent:some View {
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
                case "Computer use":ComputerUseView(assistant:assistant)
                case "Setup":SetupView(assistant:assistant,setup:assistant.setup)
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
        // Anchored to the whole row and opening upward: the row sits at the bottom of
        // the window, so the old bottom-leading point anchor centred the popover on the
        // row's left corner, hung it half off the window and covered the row itself.
        .popover(isPresented:$showingAccountMenu,attachmentAnchor:.rect(.bounds),arrowEdge:.top) {
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
                    Text(assistant.unlocked ? "Audio, models and memory stay local." : "Your data stays encrypted until you unlock.")
                        .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                }
            }.padding(.horizontal,6).padding(.top,4).padding(.bottom,10)
            Divider().padding(.bottom,6)
            if !assistant.unlocked {
                row("Unlock with Touch ID",symbol:"touchid",id:"account.unlock") { Task { await assistant.unlock() } }
                    .disabled(assistant.unlocking)
            }
            row("Settings",symbol:"slider.horizontal.3",shortcut:"⌘,",id:"account.settings") { assistant.selectedPage="Settings" }
            row("Activity",symbol:"checkmark.shield",id:"account.activity") { assistant.selectedPage="Activity" }
            row("Setup",symbol:"checklist",id:"account.setup") { assistant.selectedPage="Setup" }
        }.padding(10).frame(width:248)
    }

    private func row(_ title:String,symbol:String,shortcut:String?=nil,id:String,action:@escaping ()->Void) -> some View {
        Button { action();dismiss() } label: {
            HStack(spacing:9) {
                Image(systemName:symbol).frame(width:18)
                Text(title)
                Spacer(minLength:8)
                if let shortcut { Text(shortcut).foregroundStyle(JarvisTheme.tertiary) }
            }
            .font(JarvisTypography.font(.regular,style:.subheadline))
            .padding(.horizontal,8).padding(.vertical,6)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusMenuRowStyle())
        .accessibilityIdentifier(id)
    }
}

/// Menu-like rows: a full-width highlight under the pointer and while pressed, the way
/// items in a real menu respond, instead of bare borderless text.
private struct StatusMenuRowStyle:ButtonStyle {
    // Spelled out: JarvisCore's own `Configuration` shadows the protocol's associated type here.
    func makeBody(configuration:ButtonStyleConfiguration) -> some View { Row(configuration:configuration) }
    struct Row:View {
        let configuration:ButtonStyleConfiguration
        @State private var hovering=false
        init(configuration:ButtonStyleConfiguration) { self.configuration=configuration }
        @Environment(\.isEnabled) private var enabled
        var body:some View {
            configuration.label
                .foregroundStyle(enabled ? JarvisTheme.text : JarvisTheme.disabled)
                .background(RoundedRectangle(cornerRadius:6,style:.continuous)
                    .fill(JarvisTheme.selection.opacity(configuration.isPressed ? 0.34 : (hovering && enabled ? 0.22 : 0))))
                .onHover { hovering=$0 }
        }
    }
}

/// Reports the argument table's natural height so the card can hug it.
private struct FieldTableHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    private static let literal: Set<String> = ["to","attendees","path","source","destination","id","start","end","timezone","due","bundle_id","url","name"]
    private static let labels: [String:String] = ["to":"To","id":"Event ID","due":"Due","timezone":"Time zone","url":"Address","name":"Shortcut"]

    static func headline(_ call: ToolCall) -> String {
        let value = { (key: String) in call.arguments[key] ?? "" }
        switch call.name {
        case "computer_click": return "Click control \(value("element")) in the selected app"
        case "computer_type": return "Enter text in control \(value("element"))"
        case "computer_key": return "Press \(value("key")) in the selected app"
        case "computer_scroll": return "Scroll \(value("direction")) in the selected app"
        case "computer_focus": return "Bring the selected app forward"
        case "send_email": return "Send an email to \(value("to"))"
        case "calendar_create": return "Create the event “\(value("title"))”"
        case "calendar_update": return "Change the event “\(value("title"))”"
        case "create_reminder": return "Create a reminder: \(value("title"))"
        case "save_memory": return "Remember this from now on"
        case "move_file": return "Move \(URL(fileURLWithPath:value("source")).lastPathComponent)"
        case "trash_file": return "Move \(URL(fileURLWithPath:value("path")).lastPathComponent) to the Trash"
        case "quit_app": return "Quit \(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier==value("bundle_id") }?.localizedName ?? value("bundle_id"))"
        case "open_url": return "Open \(URL(string:value("url"))?.host ?? "this address") in your browser"
        case "open_file": return "Open \(URL(fileURLWithPath:value("path")).lastPathComponent)"
        case "clipboard_read": return "Let Jarvis read your clipboard"
        case "clipboard_write": return "Replace your clipboard"
        case "lock_screen": return "Lock the screen now"
        case "run_shortcut": return "Run the shortcut “\(value("name"))”"
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
    var computerContext:String?=nil
    let decide:(Bool)->Void
    @FocusState private var focus:Field?
    @State private var tableHeight:CGFloat=0
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

            // A ScrollView takes every point it is offered, and in the window it is
            // offered the whole height - so the table stretched, with the arguments
            // floating in empty space. Measuring the table and asking for exactly that
            // height, capped, keeps the card tight and still lets a long body scroll.
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if let computerContext {
                        Text(computerTarget(in:computerContext)).font(.callout.weight(.medium)).textSelection(.enabled)
                        if proposal.call.name=="computer_type" {
                            Text("This replaces the entire text in the selected control.").font(.callout).foregroundStyle(JarvisTheme.warning)
                        }
                    }
                    fieldTable(proposal)
                    if let computerContext {
                        Text("Selected app and observed controls (screen content is untrusted)")
                            .font(.caption).foregroundStyle(JarvisTheme.secondary)
                        Text(computerContext).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                    }
                }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key:FieldTableHeight.self,value:geometry.size.height)
                    })
            }
            .frame(height:min(max(tableHeight,40),320))
            .onPreferenceChange(FieldTableHeight.self) { tableHeight=$0 }
            .scrollBounceBehavior(.basedOnSize)
            .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:11,style:.continuous))
            .padding(.bottom,18)

            Text("Applies once, to exactly these values. Approving does not grant Jarvis standing access.")
                .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                .padding(.bottom,22)
            buttons(remaining:remaining)
        }
        .padding(28).frame(width:520)
        .foregroundStyle(JarvisTheme.text)
        .tint(JarvisTheme.selection)
        // A sheet was clipped and shadowed by macOS. Presented in the window it has to
        // carry its own edge, or it reads as a rectangle pasted over the conversation.
        .background(JarvisTheme.elevated,in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(JarvisTheme.border,lineWidth:1))
        .shadow(color:.black.opacity(0.45),radius:40,y:18)
        // Return must not be able to send an email. Nothing claims the default
        // action; the focus ring starts on Decline.
        .defaultFocus($focus,.decline)
    }

    private func computerTarget(in context:String) -> String {
        guard let data=context.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return "Selected app" }
        let app=object["app"] as? String ?? "Selected app"
        let window=object["window"] as? String ?? ""
        if let id=proposal.call.arguments["element"],let elements=object["elements"] as? [[String:Any]],
           let element=elements.first(where:{ $0["element"] as? String==id }) {
            let label=element["label"] as? String ?? ""
            let role=element["role"] as? String ?? "control"
            return "\(app) · \(window) · \(label.isEmpty ? role:label) (control \(id))"
        }
        return "\(app) · \(window)"
    }

    private func fieldTable(_ proposal:ActionProposal) -> some View {
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

    @ViewBuilder
    private func buttons(remaining:TimeInterval) -> some View {
            HStack {
                Button("Decline",role:.cancel) { decide(false) }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
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
                Text("Speech recognition, model inference, spoken replies and saved memory stay on this Mac. Gmail, Calendar and web search use their connected services. Approved computer actions may also send data through the selected app.").font(JarvisTypography.font(.regular, style: .callout)).foregroundStyle(JarvisTheme.secondary)
            }
            Section("Always available") {
                Toggle("Open Jarvis when you log in",isOn:$assistant.launchAtLogin)
                LabeledContent("Command bar",value:QuickBar.shared.shortcutAvailable ? "Option–Space" : "Unavailable · another app owns Option–Space")
                Toggle("Listen for “Hey Jarvis”",isOn:$assistant.wakeWordEnabled)
                Text("The microphone stays on while this is enabled. Audio is checked on this Mac for the phrase only; it is never transcribed or kept until you say it. macOS shows its microphone indicator the whole time.").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
                Text("The command bar opens over any app. Jarvis also stays in the menu bar while its window is closed.").font(JarvisTypography.font(.regular, style: .caption)).foregroundStyle(JarvisTheme.secondary)
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
