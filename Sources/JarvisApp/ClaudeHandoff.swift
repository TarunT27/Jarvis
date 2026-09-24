import SwiftUI
import AppKit
import JarvisCore

/// The editable hand-off the card shows. The local model fills it in as a suggestion;
/// whatever is here when the user presses Send is exactly what Claude receives.
@MainActor @Observable final class HandoffDraft {
    enum Target: Hashable { case answer, existing(String), new }
    var prompt:String
    var model:String
    var effort:String
    let suggestedModel:String
    let suggestedEffort:String
    let reason:String
    var target:Target
    var newProjectName:String
    var continueSession=true
    let privateConversation:Bool

    init(prompt:String,model:String,effort:String,reason:String,project:String,projects:[ClaudeProject],privateConversation:Bool) {
        self.prompt=prompt;self.model=model;self.effort=effort
        suggestedModel=model;suggestedEffort=effort;self.reason=reason
        self.privateConversation=privateConversation
        let name=project.trimmingCharacters(in:.whitespaces)
        if name.isEmpty { target = .answer;newProjectName="" }
        else if let known=projects.first(where:{ $0.name.caseInsensitiveCompare(name) == .orderedSame }) { target = .existing(known.name);newProjectName="" }
        else { target = .new;newProjectName=name }
    }

    var projectName:String? {
        switch target { case .answer: nil; case .existing(let name): name; case .new: newProjectName.trimmingCharacters(in:.whitespaces) }
    }
    var call:ToolCall {
        ToolCall("ask_claude",["prompt":prompt,"model":model,"effort":effort,"project":projectName ?? "","reason":reason])
    }
    var canSend:Bool {
        !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && (target != .new || newProjectName.trimmingCharacters(in:.whitespaces).range(of:ClaudePolicy.projectPattern,options:.regularExpression) != nil)
    }
}

/// A hand-off in flight, for the live progress card. Cleared when the run ends; the
/// finished message keeps the result as ordinary Markdown.
@MainActor @Observable final class ClaudeRun {
    enum Phase:Int { case sending,thinking,working,finishing }
    let messageID:UUID
    let model:String
    let effort:String
    let project:String?
    let started=Date()
    var phase:Phase = .sending
    var steps:[String]=[]
    var narration=""
    init(messageID:UUID,model:String,effort:String,project:String?) { self.messageID=messageID;self.model=model;self.effort=effort;self.project=project }
}

extension Assistant {
    var claudeAvailable:Bool { ClaudeCLI.locate() != nil }

    /// Opens the card from the composer or command bar, with whatever is typed as the prompt.
    func openClaudeHandoff() {
        guard unlocked,!busy else { if busy { error="Wait for the current response or press Stop first." };return }
        guard claudeAvailable else { error="Claude isn't installed. Install the Claude app and sign in, then try again.";return }
        let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        let hint=ClaudeCatalog.suggestion(prompt:text,building:false)
        handoff=HandoffDraft(prompt:text,model:hint.model,effort:hint.effort,reason:hint.reason,project:"",projects:claudeProjects,
                             privateConversation:promptIsPrivate || !attachedNotes.isEmpty)
    }

    /// The card's Send and Cancel. Inside a turn they answer the waiting approval;
    /// opened directly, Send starts a turn of its own.
    func confirmHandoff(_ send:Bool) {
        if approvalContinuation != nil { decide(send);return }
        guard send,let draft=handoff else { handoff=nil;return }
        handoff=nil
        teardown();let id=UUID();epoch=id;activeID=id;busy=true;input="";error=nil
        var user=ChatMessage(role:"user",content:draft.prompt,conversationID:conversation)
        user.privateContext=draft.privateConversation
        messages.append(user);touchConversation(preview:draft.prompt)
        work=Task {
            do {
                _=try await broker.request(BrokerRequest("begin",taskID:id,conversationID:conversation,value:draft.privateConversation ? "private":nil))
                await save(user)
                try await handOff(draft,id:id)
            } catch is CancellationError {
            } catch { if epoch==id { self.error=error.localizedDescription } }
            if epoch==id { busy=false;activeID=nil;if status.hasPrefix("Claude") == false { status="Ready" } }
            _=try? await broker.request(BrokerRequest("end",taskID:id))
        }
    }

    /// Authorizes exactly what the user is sending, then runs it. The user's click is the
    /// approval; proposing the edited call first keeps the broker's validation and a
    /// single-use, audited grant for the text that actually leaves the Mac.
    func handOff(_ draft:HandoffDraft,id:UUID) async throws {
        let call=draft.call
        guard let proposed=try await broker.request(BrokerRequest("propose",taskID:id,call:call)).proposal else {
            throw JarvisError.message("The hand-off was not authorized.")
        }
        _=try await broker.request(BrokerRequest("approve",proposal:proposed))
        try Task.checkCancellation();guard epoch==id else { throw CancellationError() }

        var project:ClaudeProject?
        if let name=draft.projectName { project=try claudeProjectStore.open(name) }
        let handoff=ClaudeHandoff(prompt:draft.prompt,model:draft.model,effort:draft.effort,projectPath:project?.path,
                                  resumeSession:draft.continueSession ? project?.sessionID : nil,
                                  pluginDirectories:claudePluginDirectories(),mcpConfig:claudeMCPConfig())
        try await runClaude(handoff,project:project,id:id)
        claudeProjects=claudeProjectStore.all()
    }

    /// Streams one Claude Code run into a single chat message.
    private func runClaude(_ handoff:ClaudeHandoff,project:ClaudeProject?,id:UUID) async throws {
        guard let binary=ClaudeCLI.locate() else { throw JarvisError.message("Claude isn't installed. Install the Claude app and sign in.") }
        let header="**Claude · \(ClaudeCatalog.name(of:handoff.model)) · \(handoff.effort)**"+(project.map { " · project **\($0.name)**" } ?? "")
        var message=ChatMessage(role:"assistant",content:header+"\n\nStarting…",conversationID:conversation)
        messages.append(message)
        let run=ClaudeRun(messageID:message.id,model:handoff.model,effort:handoff.effort,project:project?.name)
        claudeRun=run
        defer { if claudeRun === run { claudeRun=nil } }
        var activity:[String]=[],narration="",finished:(result:String,session:String,isError:Bool,seconds:Double,cost:Double?)?
        func render() {
            guard let index=messages.firstIndex(where:{ $0.id==message.id }) else { return }
            let steps=activity.suffix(6).map { "› \($0)" }.joined(separator:"\n")
            let tail=narration.count>1_500 ? "…"+narration.suffix(1_500) : narration
            messages[index].content=header+(steps.isEmpty ? "":"\n\n"+steps)+(tail.isEmpty ? "":"\n\n"+tail)
        }
        status="Claude is working · \(ClaudeCatalog.name(of:handoff.model))"

        let process=Process(),output=Pipe(),errors=Pipe()
        process.executableURL=binary
        process.arguments=ClaudeCLI.arguments(for:handoff)
        // Answer-only runs start in an empty folder so no project is in reach.
        let answerRoom=Configuration.support.appendingPathComponent("claude-answer",isDirectory:true)
        try? FileManager.default.createDirectory(at:answerRoom,withIntermediateDirectories:true)
        process.currentDirectoryURL=URL(fileURLWithPath:handoff.projectPath ?? answerRoom.path)
        var env=ProcessInfo.processInfo.environment
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        // Builds run npm, swift, python and friends; an app's PATH has none of them.
        env["PATH"]=["/opt/homebrew/bin","/usr/local/bin","\(home)/.local/bin","\(home)/.cargo/bin","/usr/bin","/bin","/usr/sbin","/sbin",env["PATH"] ?? ""].joined(separator:":")
        process.environment=env
        process.standardInput=FileHandle.nullDevice;process.standardOutput=output;process.standardError=errors

        try await withTaskCancellationHandler {
            try process.run()
            for try await line in output.fileHandleForReading.bytes.lines {
                for event in ClaudeStream.parse(line) {
                    switch event {
                    case .started: status="Claude is thinking · \(ClaudeCatalog.name(of:handoff.model))";run.phase = .thinking
                    case .activity(let step): activity.append(step);narration="";status="Claude · \(step)";run.phase = .working;run.steps.append(step);run.narration=""
                    case .text(let text): narration=text;run.narration=text
                    case .finished(let result,let session,let isError,let seconds,let cost): finished=(result,session,isError,seconds,cost);run.phase = .finishing
                    }
                }
                guard epoch==id else { throw CancellationError() }
                render()
            }
            process.waitUntilExit()
        } onCancel: { if process.isRunning { process.terminate() } }
        try Task.checkCancellation()

        guard let index=messages.firstIndex(where:{ $0.id==message.id }) else { return }
        if let done=finished {
            if let project,!done.session.isEmpty { claudeProjectStore.remember(session:done.session,for:project.name) }
            let minutes=Int(done.seconds)/60,seconds=Int(done.seconds)%60
            var footer="_\(minutes>0 ? "\(minutes)m ":"")\(seconds)s"+(activity.isEmpty ? "":" · \(activity.count) steps")+"_"
            if let project { footer+="  ·  [Open \(project.name) in Finder](\(URL(fileURLWithPath:project.path).absoluteString))" }
            messages[index].content=header+"\n\n"+(done.isError ? "Claude stopped: " : "")+done.result+"\n\n"+footer
            status=done.isError ? "Claude reported a problem" : "Claude finished"
        } else {
            let detail=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
                .split(separator:"\n").last { !$0.contains("[mcp-sdk]") && !$0.contains("no stdin data") }.map(String.init) ?? ""
            messages[index].content=header+"\n\nClaude ended without a result."+(detail.isEmpty ? " Open the Claude app to check that you are signed in." : " \(detail)")
            status="Claude needs attention"
        }
        message=messages[index]
        await save(message)
        if !muted { speak(finished?.isError == false ? "Claude has finished. The result is on screen." : "Claude could not finish that.",id:id) }
    }

    /// Enabled skills and plugins travel with a hand-off, so Claude works with the same
    /// know-how the user installed for Jarvis. Filled in by the extensions store.
    func claudePluginDirectories() -> [String] { extensions.pluginDirectoriesForClaude() }
    func claudeMCPConfig() -> String? { extensions.mcpConfigForClaude() }
}

struct ClaudeHandoffView:View {
    @Bindable var assistant:Assistant
    @Bindable var draft:HandoffDraft
    @FocusState private var promptFocused:Bool

    private var suggestionChanged:Bool { draft.model != draft.suggestedModel || draft.effort != draft.suggestedEffort }

    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:9) {
                Image(systemName:"arrow.up.forward.circle.fill").font(.system(size:14)).foregroundStyle(JarvisTheme.accent)
                Text("Send to Claude").font(.system(size:10,weight:.semibold)).tracking(1.4).foregroundStyle(JarvisTheme.accent)
                Spacer()
                Text("leaves this Mac").font(.caption).foregroundStyle(JarvisTheme.tertiary)
            }.padding(.bottom,12)

            Text(draft.prompt.isEmpty ? "What should Claude do?" : "Review the prompt for Claude")
                .font(JarvisTypography.font(.semibold,style:.title2)).padding(.bottom,6)
            Text("Sent to Anthropic through your Claude app sign-in. Only the text below is sent.")
                .font(JarvisTypography.font(.regular,style:.callout)).foregroundStyle(JarvisTheme.secondary).padding(.bottom,16)

            if draft.privateConversation {
                Label("This conversation includes private content (documents, mail, clipboard or memories). Check the prompt carries only what you mean to share.",systemImage:"exclamationmark.shield")
                    .font(.callout).foregroundStyle(JarvisTheme.warning).padding(.bottom,12)
            }

            TextEditor(text:$draft.prompt)
                .font(JarvisTypography.font(.regular,style:.body))
                .scrollContentBackground(.hidden).padding(10)
                .frame(minHeight:150,maxHeight:300)
                .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:11,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:11,style:.continuous).strokeBorder(promptFocused ? JarvisTheme.accent.opacity(0.6):JarvisTheme.border))
                .focused($promptFocused)
                .padding(.bottom,14)

            modelRow.padding(.bottom,12)
            projectRow.padding(.bottom,20)

            HStack {
                Text("\(draft.prompt.count) characters").font(.caption).monospacedDigit().foregroundStyle(JarvisTheme.tertiary)
                Spacer()
                Button("Cancel",role:.cancel) { assistant.confirmHandoff(false) }.keyboardShortcut(.cancelAction)
                Button("Send to Claude") { assistant.confirmHandoff(true) }
                    .keyboardShortcut(.return,modifiers:.command).buttonStyle(.borderedProminent)
                    .disabled(!draft.canSend)
            }
        }
        .padding(26).frame(width:600)
        .foregroundStyle(JarvisTheme.text).tint(JarvisTheme.selection)
        .background(JarvisTheme.elevated,in:RoundedRectangle(cornerRadius:16,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(JarvisTheme.border,lineWidth:1))
        .shadow(color:.black.opacity(0.45),radius:40,y:18)
        .onAppear { promptFocused=draft.prompt.isEmpty }
    }

    private var modelRow:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                Picker("Model",selection:$draft.model) {
                    ForEach(ClaudeCatalog.models) { model in Text(model.name).tag(model.id) }
                }.fixedSize()
                Text(ClaudeCatalog.models.first { $0.id==draft.model }?.note ?? "").font(.caption).foregroundStyle(JarvisTheme.tertiary).lineLimit(1)
                Spacer(minLength:8)
                Picker("Effort",selection:$draft.effort) {
                    ForEach(ClaudeCatalog.efforts,id:\.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth:230)
            }
            HStack(spacing:6) {
                Image(systemName:"sparkles").font(.caption)
                Text("Suggested: \(ClaudeCatalog.name(of:draft.suggestedModel)) · \(draft.suggestedEffort)"+(draft.reason.isEmpty ? "" : " — \(draft.reason)"))
                if suggestionChanged {
                    Button("Use suggestion") { draft.model=draft.suggestedModel;draft.effort=draft.suggestedEffort }.buttonStyle(.link)
                }
            }.font(.caption).foregroundStyle(JarvisTheme.secondary)
        }
    }

    private var projectRow:some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Work in",selection:$draft.target) {
                Text("Answer only · no files").tag(HandoffDraft.Target.answer)
                ForEach(assistant.claudeProjects) { project in Text(project.name).tag(HandoffDraft.Target.existing(project.name)) }
                Text("New project…").tag(HandoffDraft.Target.new)
            }.frame(maxWidth:330)
            switch draft.target {
            case .answer:
                Text("Claude answers without touching files or running commands.").font(.caption).foregroundStyle(JarvisTheme.secondary)
            case .existing(let name):
                if let project=assistant.claudeProjects.first(where:{ $0.name==name }) {
                    Text("\(project.path) · Claude can edit files and run commands only inside this folder.")
                        .font(.caption).foregroundStyle(JarvisTheme.secondary).textSelection(.enabled)
                    if project.sessionID != nil { Toggle("Continue the previous Claude session for this project",isOn:$draft.continueSession).font(.caption) }
                }
            case .new:
                TextField("Project name",text:$draft.newProjectName).textFieldStyle(.roundedBorder).frame(maxWidth:330)
                Text("Creates ~/Jarvis Builds/\(draft.newProjectName.isEmpty ? "<name>" : draft.newProjectName). Claude can edit files and run commands only inside it.")
                    .font(.caption).foregroundStyle(JarvisTheme.secondary)
            }
        }
    }
}

/// The live card shown in place of a hand-off's message while Claude works.
struct ClaudeRunView:View {
    let run:ClaudeRun
    let stop:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stages=["Sent","Thinking","Working","Finishing"]

    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:10) {
                Image(systemName:"sparkles").font(.system(size:16,weight:.semibold)).foregroundStyle(JarvisTheme.accent)
                    .symbolEffect(.pulse,options:.repeating,isActive:!reduceMotion)
                Text("Claude · \(ClaudeCatalog.name(of:run.model)) · \(run.effort)").font(JarvisTypography.font(.semibold,style:.headline))
                if let project=run.project {
                    Text(project).font(.caption.weight(.medium)).padding(.horizontal,7).padding(.vertical,2)
                        .background(JarvisTheme.selection.opacity(0.22),in:Capsule())
                }
                Spacer()
                TimelineView(.periodic(from:run.started,by:1)) { context in
                    let s=Int(context.date.timeIntervalSince(run.started))
                    Text(String(format:"%d:%02d",s/60,s%60)).font(.callout).monospacedDigit().foregroundStyle(JarvisTheme.secondary)
                }
                Button("Stop",action:stop).buttonStyle(.borderless).foregroundStyle(JarvisTheme.error)
            }
            HStack(spacing:0) {
                ForEach(Array(stages.enumerated()),id:\.offset) { index,name in
                    let reached=index<=run.phase.rawValue,current=index==run.phase.rawValue
                    VStack(spacing:5) {
                        ZStack {
                            Circle().fill(reached ? JarvisTheme.accent : JarvisTheme.border).frame(width:10,height:10)
                            if current && !reduceMotion {
                                Circle().stroke(JarvisTheme.accent.opacity(0.5),lineWidth:2).frame(width:18,height:18)
                                    .phaseAnimator([0.7,1.3]) { $0.scaleEffect($1).opacity(2-$1) } animation: { _ in .easeInOut(duration:0.9) }
                            }
                        }.frame(height:18)
                        Text(name).font(.caption2.weight(current ? .semibold:.regular)).foregroundStyle(reached ? JarvisTheme.text : JarvisTheme.tertiary)
                    }
                    if index<stages.count-1 {
                        Rectangle().fill(index<run.phase.rawValue ? JarvisTheme.accent : JarvisTheme.border).frame(height:2).padding(.bottom,16)
                    }
                }
            }
            .animation(.easeInOut(duration:0.3),value:run.phase)
            ProgressView().progressViewStyle(.linear).tint(JarvisTheme.accent)
            Text(currentLine).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if run.steps.count>1 {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(Array(run.steps.dropLast().suffix(4).enumerated()),id:\.offset) { _,step in
                        Label(step,systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(JarvisTheme.secondary).lineLimit(1)
                    }
                }
            }
            if !run.narration.isEmpty {
                Text(run.narration).font(.caption).foregroundStyle(JarvisTheme.tertiary).lineLimit(3)
            }
        }
        .padding(16)
        .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(JarvisTheme.accent.opacity(0.35),lineWidth:1))
        .accessibilityElement(children:.combine)
        .accessibilityLabel("Claude is working: \(currentLine)")
    }
    private var currentLine:String {
        switch run.phase {
        case .sending: "Sending your prompt to Claude…"
        case .thinking: "Claude is thinking…"
        case .working: run.steps.last ?? "Working…"
        case .finishing: "Wrapping up the result…"
        }
    }
}
