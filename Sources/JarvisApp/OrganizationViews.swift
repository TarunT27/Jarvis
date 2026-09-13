import SwiftUI
import JarvisCore

struct RecentChatRow: View {
    let conversation: ConversationSummary
    var compact=false

    var body: some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:conversation.projectID == nil ? "bubble.left" : "folder")
                .font(.system(size:13,weight:.medium)).foregroundStyle(JarvisTheme.accent).frame(width:16)
            VStack(alignment:.leading,spacing:3) {
                Text(conversation.title).lineLimit(1)
                if !compact {
                    Text(conversation.preview.isEmpty ? "No messages yet" : conversation.preview)
                        .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary).lineLimit(2)
                    Text(conversation.updated,style:.relative).font(JarvisTypography.font(.regular,style:.caption2)).foregroundStyle(JarvisTheme.secondary)
                }
            }
            Spacer(minLength:0)
        }
        .contentShape(Rectangle())
    }
}

struct ChatDirectoryView: View {
    @Bindable var assistant:Assistant
    let onNewProject:()->Void
    @State private var query=""
    @State private var renameTarget:OrganizationNameDraft?

    private var matchingConversations:[ConversationSummary] {
        assistant.conversations.filter { conversation in
            guard assistant.directoryProjectID == nil || conversation.projectID == assistant.directoryProjectID else { return false }
            guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return true }
            let q=query.localizedCaseInsensitiveCompare(conversation.title) == .orderedSame || conversation.title.localizedCaseInsensitiveContains(query) || conversation.preview.localizedCaseInsensitiveContains(query)
            return q
        }
    }
    private var matchingProjects:[JarvisProject] {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return assistant.projects }
        return assistant.projects.filter{$0.name.localizedCaseInsensitiveContains(query)}
    }

    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Chats & projects").font(JarvisTypography.font(.semibold,style:.largeTitle))
                    Text(assistant.directoryProjectID.flatMap { id in assistant.projects.first(where:{$0.id==id})?.name }.map { "Organized in \($0)" } ?? "Your conversations, organized locally.")
                        .foregroundStyle(JarvisTheme.secondary)
                }
                Spacer()
                Button("New project",systemImage:"folder.badge.plus",action:onNewProject).buttonStyle(.bordered)
            }
            .padding(.horizontal,28).padding(.top,28).padding(.bottom,16)
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(JarvisTheme.secondary)
                TextField("Search chats and projects",text:$query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query="" } label:{ Image(systemName:"xmark.circle.fill").foregroundStyle(JarvisTheme.secondary) }.buttonStyle(.plain) }
            }
            .padding(10).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:10))
            .padding(.horizontal,28).padding(.bottom,12)
            if assistant.directoryProjectID != nil {
                HStack {
                    Label("Project filter",systemImage:"line.3.horizontal.decrease.circle").font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                    Spacer()
                    Button("Show all chats") { assistant.directoryProjectID=nil }.buttonStyle(.borderless).font(JarvisTypography.font(.medium,style:.caption))
                }.padding(.horizontal,28).padding(.bottom,8)
            }
            List {
                Section("Projects") {
                    if matchingProjects.isEmpty { Text("No projects match your search.").foregroundStyle(JarvisTheme.secondary) }
                    ForEach(matchingProjects) { project in
                        Button {
                            assistant.selectedProjectID=project.id
                        } label: {
                            HStack(spacing:10) {
                                Image(systemName:"folder.fill").foregroundStyle(JarvisTheme.accent)
                                Text(project.name)
                                Spacer()
                                Text("\(assistant.conversations.filter{$0.projectID==project.id}.count)").font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                            }
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename project") { renameTarget=OrganizationNameDraft(kind:.project(project.id),initial:project.name,title:"Rename project") }
                            Button("Delete project",role:.destructive) { assistant.deleteProject(project.id) }
                        }
                    }
                    Button("New project",systemImage:"folder.badge.plus",action:onNewProject).buttonStyle(.borderless)
                }
                Section("Recent chats") {
                    if matchingConversations.isEmpty {
                        ContentUnavailableView {
                            Label(query.isEmpty ? "No recent chats" : "No matching chats",systemImage:"bubble.left.and.bubble.right")
                        } description: {
                            Text(query.isEmpty ? "Start a conversation and it will appear here." : "Try a different search.")
                        }
                    } else {
                        ForEach(matchingConversations) { conversation in
                            Button { assistant.openConversation(conversation.id) } label: { RecentChatRow(conversation:conversation) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename chat") { renameTarget=OrganizationNameDraft(kind:.conversation(conversation.id),initial:conversation.title,title:"Rename chat") }
                                    Menu("Move to project") {
                                        Button("No project") { assistant.assignConversation(conversation.id,to:nil) }
                                        ForEach(assistant.projects) { project in Button(project.name) { assistant.assignConversation(conversation.id,to:project.id) } }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(item:$renameTarget) { target in
            OrganizationNameSheet(target:target) { name in
                switch target.kind {
                case .conversation(let id): assistant.renameConversation(id,named:name)
                case .project(let id): assistant.renameProject(id,named:name)
                }
            }
        }
        .accessibilityIdentifier("chat-directory")
    }
}

struct OrganizationNameDraft: Identifiable {
    enum Kind { case conversation(UUID), project(UUID) }
    let id=UUID()
    let kind:Kind
    let initial:String
    let title:String
}

private struct OrganizationNameSheet: View {
    let target:OrganizationNameDraft
    let onSave:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name:String

    init(target:OrganizationNameDraft,onSave:@escaping (String)->Void) {
        self.target=target;self.onSave=onSave;_name=State(initialValue:target.initial)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(target.title).font(JarvisTypography.font(.semibold,style:.title2))
            TextField("Name",text:$name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack { Spacer();Button("Cancel",role:.cancel){ dismiss() };Button("Save",action:save).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:400)
    }
    private func save() { let value=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else { return };onSave(value);dismiss() }
}

struct NewProjectView: View {
    let onCreate:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name=""

    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Create a project").font(JarvisTypography.font(.semibold,style:.title2))
            Text("Group related conversations together on your Mac.").foregroundStyle(JarvisTheme.secondary)
            TextField("Project name",text:$name).textFieldStyle(.roundedBorder).onSubmit(create)
            HStack { Spacer();Button("Cancel",role:.cancel){ dismiss() };Button("Create",action:create).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:420)
    }
    private func create() { let value=name.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else { return };onCreate(value);dismiss() }
}
