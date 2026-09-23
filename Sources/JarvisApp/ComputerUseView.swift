import SwiftUI
import AppKit
import JarvisCore

struct ComputerUseView: View {
    @Bindable var assistant: Assistant

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                header
                permissionPanel
                taskPanel
                if assistant.computerRunning { observationPanel }
                if !assistant.computerActivity.isEmpty { activityPanel }
                if let error=assistant.error {
                    Label(error,systemImage:"exclamationmark.triangle")
                        .font(.callout).foregroundStyle(JarvisTheme.warning)
                        .textSelection(.enabled).accessibilityIdentifier("computer.error")
                }
            }
            .padding(28).frame(maxWidth:850,alignment:.leading)
            .frame(maxWidth:.infinity)
        }
        .background(JarvisTheme.canvas)
        .task { await assistant.checkComputerPermissions() }
        .onChange(of:assistant.unlocked) { _,unlocked in
            if unlocked { Task { await assistant.checkComputerPermissions() } }
        }
    }

    private var header: some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading,spacing:8) {
                Label("Computer use",systemImage:"computermouse").font(.largeTitle.weight(.semibold))
                Text("Let Jarvis work in one app, with you in control.")
                    .font(.title3).foregroundStyle(JarvisTheme.secondary)
            }
            Spacer(minLength:12)
            Button("Stop",systemImage:"stop.circle.fill") { assistant.stop() }
                .keyboardShortcut(.escape,modifiers:[])
                .controlSize(.large).tint(JarvisTheme.warning)
                .accessibilityIdentifier("computer.stop")
                .help("End the session and revoke pending actions. Escape also stops it while Jarvis is active.")
        }
    }

    private var permissionPanel: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Mac permissions").font(.headline)
            Text("Grant Screen Recording to Jarvis. For Accessibility, macOS may list Jarvis or JarvisBroker, its permission helper. You may need to reopen Jarvis after changing access.")
                .font(.callout).foregroundStyle(JarvisTheme.secondary)
            permissionRow("Accessibility",key:"accessibility",accessibility:true)
            permissionRow("Screen Recording",key:"screenRecording",accessibility:false)
            HStack {
                Button("Request permissions") { Task { await assistant.checkComputerPermissions(prompt:true) } }
                    .accessibilityIdentifier("computer.request-permissions")
                Button("Check again") { Task { await assistant.checkComputerPermissions() } }
                if assistant.computerCheckingPermissions { ProgressView().controlSize(.small) }
            }.disabled(!assistant.unlocked || assistant.busy || assistant.computerCheckingPermissions)
            if !assistant.unlocked {
                Button(assistant.unlocking ? "Unlocking…":"Unlock Jarvis") { Task { await assistant.unlock() } }
                    .disabled(assistant.unlocking).accessibilityIdentifier("computer.unlock")
            }
        }.padding(20).background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:16))
    }

    private func permissionRow(_ name:String,key:String,accessibility:Bool) -> some View {
        HStack {
            let allowed=assistant.computerPermissions[key] == true
            Label(name,systemImage:allowed ? "checkmark.circle.fill":"circle")
                .foregroundStyle(allowed ? JarvisTheme.text:JarvisTheme.secondary)
            Spacer()
            Text(allowed ? "Allowed":assistant.computerPermissions[key] == nil ? "Not checked":"Needs access").font(.caption).foregroundStyle(JarvisTheme.secondary)
            Button("Settings") { assistant.openComputerPrivacySettings(accessibility:accessibility) }
                .disabled(assistant.computerRunning)
                .accessibilityLabel("Open \(name) settings")
        }
    }

    private var taskPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("A task in a selected app").font(.headline)
            Picker("App to control",selection:$assistant.computerAppID) {
                ForEach(assistant.apps,id:\.self) { id in
                    Text(appName(id)).tag(id)
                }
            }.accessibilityIdentifier("computer.app")
            Text("This session can inspect the app’s visible content. Launch permission alone does not enable control. Each click, text entry, scroll, or shortcut asks for your approval.")
                .font(.callout).foregroundStyle(JarvisTheme.secondary)
            Text("Task").font(.subheadline.weight(.medium))
            TextEditor(text:$assistant.computerTask)
                .font(.body).frame(minHeight:90,maxHeight:140)
                .scrollContentBackground(.hidden).padding(10)
                .background(JarvisTheme.canvas,in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(JarvisTheme.border))
                .accessibilityLabel("Computer task").accessibilityIdentifier("computer.task")
            Button("Try a TextEdit task") {
                assistant.computerAppID="com.apple.TextEdit"
                assistant.computerTask="Create a new blank document in TextEdit and type: Jarvis computer-use test. Verify that this exact text appears. Leave the document unsaved."
            }.buttonStyle(.link).disabled(!assistant.apps.contains("com.apple.TextEdit"))
                .accessibilityIdentifier("computer.example")
            Toggle("Use Deep mode",isOn:$assistant.deep)
                .disabled(!assistant.models.contains(Configuration.deep))
            HStack {
                Button("Start task",systemImage:"play.fill") { assistant.startComputerTask() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canStart).accessibilityIdentifier("computer.start")
                Text(assistant.computerStopShortcutAvailable ? "Local inference · five minutes maximum · ⌃⌥Esc stops from any app":"Local inference · five minutes maximum · use Stop in Jarvis to take over")
                    .font(.caption).foregroundStyle(JarvisTheme.secondary)
            }
        }
        .disabled(assistant.busy)
        .padding(20).background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:16))
    }

    private var canStart: Bool {
        assistant.unlocked && !assistant.busy && !assistant.computerTask.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            && assistant.computerPermissions["accessibility"] == true
            && assistant.computerPermissions["screenRecording"] == true
            && assistant.apps.contains(assistant.computerAppID)
    }

    private var observationPanel: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                ProgressView().controlSize(.small)
                Text(assistant.status).font(.headline)
            }
            Text(assistant.computerUsesVision ? "Using local vision and app controls":"Using app controls; this model does not advertise vision")
                .font(.caption).foregroundStyle(JarvisTheme.secondary)
            if let encoded=assistant.computerScreenshot,let data=Data(base64Encoded:encoded),let image=NSImage(data:data) {
                Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:280)
                    .clipShape(RoundedRectangle(cornerRadius:10))
                    .accessibilityLabel("Latest observation of the selected app")
            }
            DisclosureGroup("Observed controls") {
                Text(assistant.computerObservation).font(.system(.caption,design:.monospaced))
                    .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }
            Text("Screen previews are held only during this session. Stop clears them.")
                .font(.caption).foregroundStyle(JarvisTheme.secondary)
        }.padding(20).background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:16))
    }

    private var activityPanel: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Task activity").font(.headline)
            ForEach(Array(assistant.computerActivity.enumerated()),id:\.offset) { _,entry in
                Text(entry).font(.callout).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(20).background(JarvisTheme.surface,in:RoundedRectangle(cornerRadius:16))
    }

    private func appName(_ id:String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier:id)?.deletingPathExtension().lastPathComponent ?? id
    }
}
