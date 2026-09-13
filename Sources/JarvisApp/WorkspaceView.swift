import SwiftUI
import JarvisCore

/// The editor owns an unsaved draft; Assistant and the XPC vault own saved content.
struct WorkspaceView: View {
    @Bindable var assistant:Assistant
    @State private var query=""
    @State private var draft:WorkspaceItem?
    @State private var deleting:WorkspaceItem?
    private var items:[WorkspaceItem] {
        assistant.workspace.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Notes & prompts").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu("New",systemImage:"plus") {
                    Button("Note") { draft=WorkspaceItem(kind:.note,title:"",body:"") }
                    Button("Prompt") { draft=WorkspaceItem(kind:.prompt,title:"",body:"") }
                }.disabled(!assistant.unlocked)
            }
            Text("Saved on this Mac. Attach notes as context or review a reusable prompt before sending.")
                .foregroundStyle(JarvisTheme.secondary)
            TextField("Search notes and prompts",text:$query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search notes and prompts")
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Your workspace is ready" : "No matches",systemImage:"note.text",description:Text("Create a note or a reusable prompt using New."))
            } else {
                List(items) { item in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Label(item.title,systemImage:item.kind == .note ? "note.text":"text.bubble").font(.headline)
                            Spacer()
                            Text(item.kind == .note ? "Note":"Prompt").font(.caption).foregroundStyle(JarvisTheme.secondary)
                        }
                        Text(item.body).lineLimit(3).foregroundStyle(JarvisTheme.secondary)
                        HStack {
                            Text(item.updated,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(JarvisTheme.secondary)
                            Spacer()
                            Button(item.kind == .note ? "Attach to chat":"Use prompt") { assistant.useWorkspace(item) }.disabled(assistant.busy)
                            Button("Edit") { draft=item }
                            Button("Delete",role:.destructive) { deleting=item }
                        }
                    }.padding(.vertical,8)
                }.scrollContentBackground(.hidden)
            }
        }.padding(28)
        .task { await assistant.loadWorkspace() }
        .sheet(item:$draft) { item in WorkspaceEditor(assistant:assistant,item:item) }
        .confirmationDialog("Delete this workspace item?",isPresented:Binding(get:{deleting != nil},set:{if !$0 { deleting=nil }})) {
            if let item=deleting { Button("Delete",role:.destructive) { Task { await assistant.deleteWorkspace(item) };deleting=nil } }
        } message: { Text("The item and its search entry will be removed. Text already quoted in conversations remains in chat history.") }
    }
}
private struct WorkspaceEditor: View {
    let assistant:Assistant
    @State var item:WorkspaceItem
    @State private var saving=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(item.kind == .note ? "Edit note":"Edit prompt").font(.title2)
            TextField("Title",text:$item.title).textFieldStyle(.roundedBorder).accessibilityLabel("Workspace item title")
            TextEditor(text:$item.body).font(.body).frame(minHeight:240).accessibilityLabel("Workspace item content")
            if item.kind == .prompt {
                Text("Optional variables: {{date}}, {{time}}, {{timezone}}. Prompts never grant tool permissions.").font(.caption).foregroundStyle(JarvisTheme.secondary)
            }
            HStack {
                Text("Encrypted on this Mac").font(.caption).foregroundStyle(JarvisTheme.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…":"Save") {
                    saving=true
                    Task { if await assistant.saveWorkspace(item) { dismiss() };saving=false }
                }.keyboardShortcut(.defaultAction).disabled(saving || (try? item.validated()) == nil)
            }
        }.padding(24).frame(width:560).jarvisAppearance()
    }
}

struct GenerationSettingsView: View {
    @Bindable var assistant:Assistant
    var body:some View {
        Form {
            Text("Local response settings").font(.headline)
            Slider(value:$assistant.generationOptions.temperature,in:0...1,step:0.1) {
                Text("Creativity")
            }.accessibilityValue(assistant.generationOptions.temperature.formatted(.number.precision(.fractionLength(1))))
            Picker("Maximum response",selection:$assistant.generationOptions.maximumTokens) {
                ForEach([256,512,1024,2048],id:\.self) { Text("\($0) tokens").tag($0) }
            }
            Toggle("Include saved memories",isOn:$assistant.includeSavedMemories)
            Text("For public web search, turn off saved memories and start a new chat without private attachments.").font(.caption).foregroundStyle(JarvisTheme.secondary)
            Text("Applies to the next request. Context stays at 8K; only one model is loaded. These session settings reset when Jarvis closes.")
                .font(.caption).foregroundStyle(JarvisTheme.secondary)
        }.padding(20).frame(width:330).disabled(assistant.busy).jarvisAppearance()
    }
}
