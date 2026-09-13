import SwiftUI
import JarvisCore

/// Presentation only: conversation, voice and authorization stay owned by Assistant.
struct ChatView: View {
    @Bindable var assistant: Assistant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showingVoiceDetail = false
    @State private var showingGenerationSettings = false
    /// Streaming must not steal the scroll from someone reading back through a
    /// reply, so auto-scroll only follows when the view was already at the end.
    @State private var atBottom = true
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15

    /// One measure for the conversation and the composer. They used to cap at
    /// 800 and 1000, so their edges never lined up at any window size.
    private let measure: CGFloat = 820

    private var projectName: String {
        assistant.projects.first(where: { $0.id == assistant.selectedProjectID })?.name ?? "Personal"
    }
    private var conversationTitle: String {
        guard let id = assistant.messages.first?.conversationID,
              let conversation = assistant.conversations.first(where: { $0.id == id }) else {
            return "New conversation"
        }
        return conversation.title
    }
    private var shortcut: String {
        assistant.shortcutOption == 0 ? "Control–Option–Space" : "Command–Option–Space"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        introduction
                        if assistant.messages.isEmpty { suggestions }
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(assistant.messages) { message in
                                ConversationMessageView(message: message)
                                    .transition(.opacity.combined(with: .offset(y: 7)))
                                    .contextMenu {
                                        Button("Copy message") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(message.content,forType:.string) }
                                        Button("Save as note") { Task { _=await assistant.saveWorkspace(WorkspaceItem(kind:.note,title:String(message.content.prefix(60)).replacingOccurrences(of:"\n",with:" "),body:message.content)) } }.disabled(message.content.isEmpty || assistant.busy)
                                    }.id(message.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .animation(JarvisMotion.settling(reduceMotion), value: assistant.messages.count)
                    }
                    .frame(maxWidth: measure, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 140
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onChange(of: assistant.messages.last?.content) { _, _ in
                    guard atBottom else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    guard atBottom else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .overlay(alignment: .bottom) { jumpToLatest(proxy: proxy) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composerDock }
        }
        .background(JarvisTheme.canvas)
        .onChange(of: assistant.awaitingTranscriptReview) { _, awaiting in
            if awaiting { focusComposer() }
        }
    }

    /// Focusing a macOS text field selects its contents. After a transcript or a
    /// suggestion the caret belongs at the end, ready to be corrected.
    private func focusComposer() {
        composerFocused = true
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
        }
    }

    @ViewBuilder
    private func jumpToLatest(proxy: ScrollViewProxy) -> some View {
        if !atBottom && !assistant.messages.isEmpty {
            Button {
                withAnimation(JarvisMotion.settling(reduceMotion)) { proxy.scrollTo("bottom", anchor: .bottom) }
            } label: {
                Label("Jump to latest", systemImage: "arrow.down")
                    .font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(JarvisTheme.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(JarvisTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.opacity)
            .accessibilityIdentifier("chat.jump-to-latest")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(JarvisTheme.secondary)
            Text(projectName).foregroundStyle(JarvisTheme.secondary).lineLimit(1)
            Text("/").foregroundStyle(JarvisTheme.tertiary)
            Text(conversationTitle).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Menu("Conversation",systemImage:"ellipsis.circle") {
                Button("Export as Markdown") { assistant.exportConversation(markdown:true) }
                Button("Export as JSON") { assistant.exportConversation(markdown:false) }
            }.labelStyle(.iconOnly).disabled(assistant.messages.isEmpty || assistant.busy)
                .accessibilityLabel("Export conversation")
            // "Local" is stated once in the sidebar's status row and once beside
            // the model name, where it qualifies the thing it describes. A third
            // lock in the toolbar only diluted both.
            Button { assistant.stop() } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.borderless)
            .help("Stop generation, speech and pending actions (Escape)")
            .accessibilityIdentifier("chat.stop")
        }
        .font(.callout).padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((assistant.messages.first?.created ?? Date()).formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(.caption).textCase(.uppercase).foregroundStyle(JarvisTheme.secondary)
            Text("A little room to focus.")
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.7).accessibilityAddTraits(.isHeader)
            if assistant.messages.isEmpty {
                Text("What can I help you with?").font(.title3).foregroundStyle(JarvisTheme.secondary)
            }
            if !assistant.unlocked {
                HStack(spacing: 10) {
                    Label("Unlock to use your private workspace", systemImage: "lock")
                        .font(.callout).foregroundStyle(JarvisTheme.secondary)
                    Button(assistant.unlocking ? "Unlocking…" : "Unlock") {
                        Task { await assistant.unlock() }
                    }.disabled(assistant.unlocking).accessibilityIdentifier("chat.unlock")
                }
                .transition(.opacity)
            }
        }
        .animation(JarvisMotion.nudging(reduceMotion), value: assistant.unlocked)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["Help me plan my day", "Find a document in my approved folders", "Remember that I prefer concise replies"], id: \.self) { suggestion in
                Button {
                    assistant.input = suggestion
                    focusComposer()
                } label: {
                    HStack {
                        Text(suggestion)
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.up.left").foregroundStyle(JarvisTheme.tertiary)
                    }.padding(.vertical, 13).contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: bodySize))
                Divider().overlay(JarvisTheme.border.opacity(0.5))
            }
        }.frame(maxWidth: 470).padding(.top, 12)
    }

    private var composerDock: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(assistant.attachedNotes) { note in
                    HStack {
                        Label(note.title,systemImage:"note.text").lineLimit(1)
                        Spacer()
                        Button("Remove") { assistant.attachedNotes.removeAll { $0.id==note.id } }
                            .accessibilityLabel("Remove attached note \(note.title)")
                    }.font(.caption)
                }
                if assistant.promptIsPrivate {
                    Text("Saved prompt · review before sending · stays local").font(.caption).foregroundStyle(JarvisTheme.secondary)
                }
                if assistant.screenImage != nil {
                    HStack {
                        Label("Screen attached · stays local", systemImage: "display")
                        Spacer()
                        Button("Remove") { assistant.screenImage = nil }
                    }.font(.caption).foregroundStyle(JarvisTheme.secondary)
                }
                if assistant.recording {
                    listeningHeader
                } else if assistant.awaitingTranscriptReview {
                    transcriptHeader
                } else if let presence = assistant.voicePresenceState {
                    presenceRow(presence)
                }
                TextField("Ask Jarvis, or tap the microphone…", text: $assistant.input, axis: .vertical)
                    .font(.system(size: bodySize)).textFieldStyle(.plain).lineLimit(1...5)
                    .padding(.horizontal, 4).padding(.top, 3)
                    .onSubmit { assistant.send() }
                    .accessibilityLabel("Message Jarvis")
                    .accessibilityIdentifier("chat.input")
                    .focused($composerFocused)
                controlRow
            }
            .padding(20).jarvisComposerGlass(focused: composerFocused, listening: assistant.recording)
            .animation(JarvisMotion.settling(reduceMotion), value: assistant.voicePresenceState)
            .animation(JarvisMotion.settling(reduceMotion), value: assistant.awaitingTranscriptReview)
            HStack(spacing: 8) {
                Text(assistant.recording ? "Tap the microphone to finish" : "Press \(shortcut) to talk")
                Text("·")
                Text(assistant.status).lineLimit(1)
                    .accessibilityIdentifier("chat.status")
            }.font(.caption).foregroundStyle(JarvisTheme.secondary)
        }
        .frame(maxWidth: measure)
        .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    /// A live session, with everything needed to govern it: what it is doing, how long
    /// it has been doing it, and two ways out that are not "send".
    private var listeningHeader: some View {
        HStack(spacing: 12) {
            VoiceLevelBars(level: assistant.voiceLevel, paused: assistant.micPaused)
            Text(assistant.micPaused ? "PAUSED" : "LISTENING")
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6)
                .foregroundStyle(assistant.micPaused ? JarvisTheme.secondary : JarvisTheme.recording)
            Text(elapsedLabel)
                .font(.caption).monospacedDigit().foregroundStyle(JarvisTheme.tertiary)
            Spacer(minLength: 8)
            Button { assistant.toggleMicPause() } label: {
                Label(assistant.micPaused ? "Resume" : "Pause",
                      systemImage: assistant.micPaused ? "mic" : "mic.slash")
                    .font(.caption).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundStyle(JarvisTheme.secondary)
            .help(assistant.micPaused ? "Start hearing again" : "Stop hearing without ending the recording")
            .accessibilityIdentifier("chat.mic-pause")
            Button { assistant.cancelListening() } label: {
                Label("Discard", systemImage: "xmark").font(.caption).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain).foregroundStyle(JarvisTheme.secondary)
            .help("End the recording and throw it away")
            .accessibilityIdentifier("chat.discard-recording")
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Divider().overlay(JarvisTheme.border) }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assistant.micPaused ? "Microphone paused" : "Listening")
    }

    private var elapsedLabel: String {
        let seconds = Int(assistant.listeningElapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var transcriptHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.healthy)
            Text("Transcribed on this Mac").font(.caption).foregroundStyle(JarvisTheme.secondary)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func presenceRow(_ presence: VoicePresenceState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: presence.symbol).foregroundStyle(presence.tint)
            Text(presence.detail).font(.callout)
            Spacer()
            Button { showingVoiceDetail.toggle() } label: {
                Image(systemName: "waveform.circle")
            }.buttonStyle(.plain).accessibilityLabel("Show voice activity")
            .popover(isPresented: $showingVoiceDetail) {
                VoicePresenceView(state: presence, audioLevel: assistant.voiceLevel)
                    .padding(20).frame(width: 300).jarvisAppearance()
            }
        }.transition(.opacity)
    }

    /// Five controls at rest, not seven. Response settings moved into the context
    /// menu; mute appears only while Jarvis is speaking, which is the only moment
    /// it means anything.
    private var controlRow: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Notes & prompts",systemImage:"note.text") { assistant.selectedPage="Notes & prompts" }
                ForEach(assistant.workspace.filter { $0.kind == .prompt }.prefix(10)) { item in
                    Button(item.title) { assistant.useWorkspace(item) }
                }
                Divider()
                Button("Attach current screen", systemImage: "display") {
                    Task { await assistant.captureScreen() }
                }
                Button("Local response settings…", systemImage: "slider.horizontal.3") {
                    showingGenerationSettings = true
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 19, weight: .regular)).frame(width: 32, height: 32)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add context").accessibilityLabel("Add context")
                .accessibilityIdentifier("chat.context")
                .popover(isPresented: $showingGenerationSettings) { GenerationSettingsView(assistant: assistant) }
            modelMenu
            Label("Local", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(JarvisTheme.secondary)
                .labelStyle(LocalStatusLabelStyle())
                .help("This model runs on your Mac")
            Spacer(minLength: 4)
            if assistant.awaitingTranscriptReview {
                Button { assistant.startListening() } label: {
                    Label("Record again", systemImage: "arrow.counterclockwise")
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(JarvisTheme.strongBorder, lineWidth: 1))
                }.buttonStyle(.plain).foregroundStyle(JarvisTheme.secondary)
                    .transition(.opacity)
                    .accessibilityIdentifier("chat.record-again")
            }
            if assistant.voicePresenceState == .speaking || assistant.muted {
                Button {
                    assistant.muted.toggle()
                    if assistant.muted { assistant.stop() }
                } label: {
                    Image(systemName: assistant.muted ? "speaker.slash" : "speaker.wave.2")
                        .frame(width: 28, height: 32)
                }.buttonStyle(.plain).foregroundStyle(JarvisTheme.secondary)
                    .transition(.opacity)
                    .help(assistant.muted ? "Enable spoken replies" : "Mute spoken replies")
                    .accessibilityLabel(assistant.muted ? "Enable spoken replies" : "Mute spoken replies")
                    .accessibilityIdentifier("chat.mute")
            }
            voiceButton
            Button { assistant.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .medium))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(canSend ? JarvisTheme.buttonInk : JarvisTheme.disabled)
                    .background(canSend ? JarvisTheme.primaryFill : JarvisTheme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(canSend ? .clear : JarvisTheme.border, lineWidth: 1))
                    .scaleEffect(canSend ? 1 : 0.94)
            }.buttonStyle(.plain).disabled(!canSend)
                .animation(JarvisMotion.nudging(reduceMotion), value: canSend)
                .accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
        }
        // Controls that do nothing mid-recording recede instead of disappearing,
        // so nothing in the row reflows while the panel is open.
        .animation(JarvisMotion.settling(reduceMotion), value: assistant.awaitingTranscriptReview)
        .animation(JarvisMotion.settling(reduceMotion), value: assistant.muted)
    }

    private var canSend: Bool {
        !assistant.busy && !assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var modelMenu: some View {
        Menu {
            Button { assistant.deep = false } label: {
                Label("Everyday · Qwen3.5 9B", systemImage: assistant.deep ? "cpu" : "checkmark")
            }
            Button { assistant.deep = true } label: {
                Label("Deep · Qwen3.8 27B", systemImage: assistant.deep ? "checkmark" : "cpu")
            }.disabled(!assistant.models.contains(Configuration.deep))
        } label: {
            HStack(spacing: 8) {
                Text(assistant.deep ? "Qwen3.8 27B" : "Qwen3.5 9B").font(.callout).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(JarvisTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(JarvisTheme.border, lineWidth: 1))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(assistant.busy || assistant.recording)
            .opacity(assistant.recording ? 0.4 : 1)
            .accessibilityLabel("Local model").accessibilityValue(assistant.deep ? "Deep, Qwen3.8 27B" : "Everyday, Qwen3.5 9B")
            .accessibilityIdentifier("chat.model")
    }
    /// A microphone, not the Jarvis mark. The mark is an identity, and an identity
    /// carries no affordance: it does not tell you that pressing it records.
    ///
    /// Tap to open a listening session, tap again to finish it. Holding is gone: a
    /// held button cannot be a conversation, it has to be aimed, and every press
    /// primitive on macOS disagrees about when a hold ends. A lit microphone that you
    /// switch off is the model people already have from every call app.
    private var voiceButton: some View {
        Button { assistant.toggleListening() } label: {
            Image(systemName: voiceSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(assistant.recording ? JarvisTheme.buttonInk : JarvisTheme.accent)
                .frame(width: 42, height: 42)
                .background(assistant.recording ? JarvisTheme.accent : JarvisTheme.surface, in: Circle())
                .overlay(Circle().strokeBorder(JarvisTheme.secondary.opacity(0.35), lineWidth: 0.5))
                .contentShape(Circle())
                .animation(JarvisMotion.nudging(reduceMotion), value: assistant.recording)
                .animation(JarvisMotion.nudging(reduceMotion), value: assistant.micPaused)
        }
        .buttonStyle(.plain)
        .help(assistant.recording ? "Finish recording (\(shortcut))" : "Start recording (\(shortcut))")
        .accessibilityLabel(assistant.recording ? "Finish recording" : "Start recording")
        .accessibilityValue(assistant.recording
            ? (assistant.micPaused ? "Recording, microphone paused" : "Recording")
            : "Microphone idle")
        .accessibilityHint("Tap to start, tap again to finish. \(shortcut) does the same.")
        .accessibilityIdentifier("chat.hold-to-talk")
    }

    private var voiceSymbol: String {
        guard assistant.recording else { return "mic" }
        return assistant.micPaused ? "mic.slash.fill" : "mic.fill"
    }
}

/// Six bars driven by the same level the presence view uses. Reduce Motion holds
/// them at rest; the adjacent "LISTENING" label already carries the state.
private struct VoiceLevelBars: View {
    let level: CGFloat
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let weights: [CGFloat] = [0.34, 0.68, 1.0, 0.52, 0.82, 0.28]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .frame(width: 3, height: 6 + (paused ? 0 : reduceMotion ? 6 : max(0, min(1, level)) * 16) * weight)
            }
        }
        .frame(height: 22, alignment: .bottom)
        .foregroundStyle(paused ? JarvisTheme.disabled : JarvisTheme.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private struct LocalStatusLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(JarvisTheme.healthy)
            configuration.title
        }
    }
}

private struct ConversationMessageView: View {
    let message: ChatMessage
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if isUser {
                Text(message.content).textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 13)
                    .background(JarvisTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(JarvisTheme.border, lineWidth: 1))
                    .frame(maxWidth: 640, alignment: .trailing)
                Text(message.created, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(JarvisTheme.tertiary)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    JarvisMark().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Text("Jarvis").font(.headline)
                            Text(message.created, format: .dateTime.hour().minute())
                                .font(.caption).foregroundStyle(JarvisTheme.tertiary)
                        }
                        MessageMarkdownView(content:message.content.isEmpty ? "Working on it…" : message.content)
                            .frame(maxWidth:.infinity,alignment:.leading)
                        if let stats=message.statistics {
                            HStack(spacing:8) {
                                if let tokens=stats.outputTokens { Text("\(tokens) tokens") }
                                if let rate=stats.tokensPerSecond { Text("\(rate.formatted(.number.precision(.fractionLength(1)))) tokens/s") }
                            }.font(.caption).foregroundStyle(JarvisTheme.tertiary).monospacedDigit()
                                .help("Final model call only; excludes speech and tool latency. Model: \(stats.model)")
                        }
                    }
                }
            }
        }
        .font(.system(size: bodySize)).frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : "Jarvis")
    }
}
