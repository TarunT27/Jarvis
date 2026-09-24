import SwiftUI
import AppKit
import ServiceManagement
import Carbon
import JarvisCore

/// A borderless panel that takes the keyboard without activating Jarvis, so the
/// command bar opens over whatever app you are in and hands focus straight back.
private final class QuickPanel:NSPanel {
    override var canBecomeKey:Bool { true }
    override var canBecomeMain:Bool { false }
}

/// The always-available entry point: a global shortcut opens a Spotlight-style bar
/// that talks to the current conversation. Approvals appear in the bar itself,
/// because the main window may not be open.
@MainActor final class QuickBar {
    static let shared=QuickBar()
    private var panel:QuickPanel?
    private weak var assistant:Assistant?
    private let shortcut=PushToTalkShortcut(identifier:3,key:49,modifiers:UInt32(optionKey))
    /// Set by a SwiftUI scene. An NSHostingView outside any scene has no working
    /// openWindow action, so the bar borrows the one the menu and main window carry.
    var openMainWindow:(()->Void)?
    var shortcutAvailable:Bool { shortcut.isRegistered }
    private var escapeMonitor:Any?
    static let size=NSSize(width:700,height:520)

    func install(_ assistant:Assistant) {
        self.assistant=assistant
        shortcut.onPress={ [weak self] in self?.toggle() }
        shortcut.onRelease={}
    }

    func toggle() { if panel?.isVisible == true && panel?.isKeyWindow == true { hide() } else { show() } }

    func show() {
        guard let assistant else { return }
        let panel=self.panel ?? make(assistant)
        // Open on the screen you are working on, not always the main one.
        let screen=NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation,$0.frame,false) } ?? NSScreen.main
        if let visible=screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x:visible.midX-Self.size.width/2,y:visible.maxY-visible.height*0.18-Self.size.height))
        }
        assistant.quickBarVisible=true
        panel.makeKeyAndOrderFront(nil)
        // On the first open the view is created in the same pass, and a focus request
        // made before the panel is key is dropped. Ask again once it is.
        DispatchQueue.main.async { assistant.quickBarFocus+=1 }
    }

    func hide() {
        panel?.orderOut(nil)
        assistant?.quickBarVisible=false
    }

    private func make(_ assistant:Assistant) -> QuickPanel {
        let panel=QuickPanel(contentRect:NSRect(origin:.zero,size:Self.size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        panel.isFloatingPanel=true;panel.level = .floating;panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.transient]
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
        panel.isMovableByWindowBackground=true
        let host=NSHostingView(rootView:QuickBarView(assistant:assistant,close:{ [weak self] in self?.hide() })
            // Not jarvisAppearance(): that paints the window canvas, and everything around
            // the bar has to stay see-through.
            .environment(\.font,JarvisTypography.font(.regular,style:.body))
            .foregroundStyle(JarvisTheme.text).tint(JarvisTheme.selection))
        host.frame=NSRect(origin:.zero,size:Self.size)
        panel.contentView=host
        // Clicking away closes an idle bar. A turn in flight or a pending approval keeps
        // it up: the answer, or the question it is waiting on, belongs here.
        NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:panel,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,let assistant=self.assistant,!assistant.busy,assistant.proposal==nil,assistant.handoff==nil,!assistant.recording else { return }
                self.hide()
            }
        }
        // Escape has to be caught before the text field: its field editor treats Escape
        // as "complete this word", opens a completion list, and the next keystrokes pick
        // from it - neither cancelOperation nor onExitCommand ever sees the key. While an
        // approval is up, Escape passes through so it keeps meaning Decline.
        escapeMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode==53,let self,let panel=self.panel,event.window===panel,
                  self.assistant?.proposal==nil,self.assistant?.handoff==nil else { return event }
            self.hide()
            return nil
        }
        self.panel=panel
        return panel
    }
}

struct QuickBarView:View {
    @Bindable var assistant:Assistant
    let close:()->Void
    @FocusState private var focused:Bool

    /// Only this bar's own exchange is shown, so opening it does not dump an old chat on you.
    private var exchange:[ChatMessage] {
        guard let start=assistant.quickBarTurnStart,start<=assistant.messages.count else { return [] }
        return Array(assistant.messages[start...]).filter { !$0.content.isEmpty }
    }

    var body:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:0) {
                inputRow
                if let draft=assistant.handoff {
                    Divider().overlay(JarvisTheme.border)
                    ScrollView { ClaudeHandoffView(assistant:assistant,draft:draft).scaleEffect(0.92).padding(.vertical,-12) }
                        .frame(maxHeight:420)
                } else if let proposal=assistant.proposal {
                    Divider().overlay(JarvisTheme.border)
                    ApprovalView(proposal:proposal,computerContext:proposal.call.name.hasPrefix("computer_") ? assistant.computerObservation:nil) { assistant.decide($0) }
                        .frame(maxHeight:360)
                } else if !exchange.isEmpty || assistant.error != nil {
                    Divider().overlay(JarvisTheme.border)
                    response
                }
                footer
            }
            .background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:18,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:18,style:.continuous).strokeBorder(JarvisTheme.border))
            .shadow(color:.black.opacity(0.35),radius:24,y:12)
            .padding(24)
            Spacer(minLength:0)
        }
        .frame(width:QuickBar.size.width,height:QuickBar.size.height,alignment:.top)
        .onChange(of:assistant.quickBarFocus,initial:true) { _,_ in focused=true }
    }

    private var inputRow:some View {
        HStack(spacing:12) {
            JarvisMark().frame(width:22,height:22)
            TextField(assistant.recording ? "Listening…" : "Ask Jarvis, or tell it what to do on your Mac",text:$assistant.input,axis:.vertical)
                .textFieldStyle(.plain).font(JarvisTypography.font(.regular,style:.title3))
                .lineLimit(1...4).focused($focused)
                .onSubmit { submit() }
                .disabled(!assistant.unlocked)
            if assistant.busy { ProgressView().controlSize(.small) }
            Button { assistant.toggleListening() } label: {
                Image(systemName:assistant.conversationActive ? "stop.circle.fill":"mic")
                    .foregroundStyle(assistant.recording ? JarvisTheme.recording:JarvisTheme.secondary)
            }
            .buttonStyle(.borderless).help(assistant.conversationActive ? "End the spoken conversation":"Talk to Jarvis")
            .onChange(of:assistant.conversationActive) { _,active in if active { assistant.quickBarTurnStart=assistant.messages.count } }
        }
        .padding(.horizontal,18).padding(.vertical,16)
    }

    private var response:some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    ForEach(exchange) { message in
                        if message.role=="user" {
                            Text(message.content).font(JarvisTypography.font(.medium,style:.callout)).foregroundStyle(JarvisTheme.secondary)
                        } else {
                            MessageMarkdownView(content:message.content).foregroundStyle(JarvisTheme.text)
                        }
                    }
                    if let error=assistant.error {
                        Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(JarvisTheme.error)
                    }
                    Color.clear.frame(height:1).id("end")
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,18).padding(.vertical,14)
            }
            .frame(maxHeight:300)
            .onChange(of:assistant.messages.last?.content) { _,_ in proxy.scrollTo("end",anchor:.bottom) }
        }
    }

    private var footer:some View {
        HStack(spacing:14) {
            Text(assistant.status).lineLimit(1)
            Spacer()
            if assistant.claudeAvailable {
                Button("Send to Claude") { assistant.quickBarTurnStart=assistant.messages.count;assistant.openClaudeHandoff() }
                    .buttonStyle(.borderless).keyboardShortcut(.return,modifiers:[.command,.shift])
            }
            Button("New") { assistant.newChat();assistant.quickBarTurnStart=nil;focused=true }
                .buttonStyle(.borderless).keyboardShortcut("n",modifiers:.command)
            Button("Open Jarvis") { QuickBar.shared.openMainWindow?();NSApp.activate(ignoringOtherApps:true);close() }
                .buttonStyle(.borderless).keyboardShortcut("o",modifiers:.command)
            if assistant.busy { Button("Stop") { assistant.stop() }.buttonStyle(.borderless) }
        }
        .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.tertiary)
        .padding(.horizontal,18).padding(.vertical,10)
        .background(JarvisTheme.elevated.opacity(0.5),in:UnevenRoundedRectangle(bottomLeadingRadius:18,bottomTrailingRadius:18,style:.continuous))
    }

    private func submit() {
        guard !assistant.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!assistant.busy else { return }
        assistant.quickBarTurnStart=assistant.messages.count
        assistant.send()
    }
}

/// Launch at login through the system's own login-item service, which lists Jarvis in
/// System Settings › General › Login Items where it can be switched off.
enum LoginItem {
    static var enabled:Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on:Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

