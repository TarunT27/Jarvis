import SwiftUI
import AppKit
import CryptoKit
import JarvisCore

/// First-run provisioning. Each component is checked from what is actually on disk or
/// answering on the loopback port, never from a remembered flag, so the page is also
/// the honest answer to "why doesn't voice work?".
@MainActor @Observable final class SetupModel {
    enum Component: String, CaseIterable, Identifiable {
        case service="Local model service", everyday="Everyday model", recognition="Speech recognition", voice="Natural voice and “Hey Jarvis”", deep="Deep model"
        var id:String { rawValue }
    }
    var progress:[Component:Double]=[:]
    var detail:[Component:String]=[:]
    var failure:[Component:String]=[:]
    private var tasks:[Component:Task<Void,Never>]=[:]

    /// The pinned speech model; the hash is checked before the file is put in place.
    static let whisperURL=URL(string:"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
    static let whisperSHA256="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

    func installed(_ c:Component,_ assistant:Assistant) -> Bool {
        let paths=RuntimePaths.current
        switch c {
        case .service: return paths.ollama != nil && assistant.runtimeReady
        case .everyday: return assistant.models.contains(Configuration.everyday)
        case .deep: return assistant.models.contains(Configuration.deep)
        case .recognition: return LocalTranscriber.available
        case .voice: return paths.naturalVoiceInstalled && paths.wakeWordInstalled
        }
    }
    /// Chat needs the first two; the rest improve it but have fallbacks.
    func essentialsMissing(_ assistant:Assistant) -> Bool {
        !installed(.service,assistant) || !installed(.everyday,assistant)
    }
    func running(_ c:Component) -> Bool { tasks[c] != nil }

    func cancel(_ c:Component) { tasks.removeValue(forKey:c)?.cancel();progress[c]=nil;detail[c]=nil }

    func install(_ c:Component,_ assistant:Assistant) {
        guard tasks[c]==nil else { return }
        failure[c]=nil;progress[c]=0
        tasks[c]=Task { [weak self] in
            guard let self else { return }
            do {
                switch c {
                case .service:
                    if RuntimePaths.current.ollama == nil { NSWorkspace.shared.open(URL(string:"https://ollama.com/download/mac")!) }
                    self.detail[c]="Starting the local model service"
                    await assistant.retryRuntime()
                    if !assistant.runtimeReady { throw JarvisError.message(RuntimePaths.current.ollama == nil ? "Install Ollama from the page that just opened, then choose Check again." : (assistant.error ?? "The model service did not start.")) }
                case .everyday,.deep:
                    let name=c == .everyday ? Configuration.everyday:Configuration.deep
                    try await ModelClient().pull(model:name) { fraction,status in
                        await MainActor.run { self.progress[c]=fraction;self.detail[c]=status.capitalized }
                    }
                    await assistant.retryRuntime()
                case .recognition:
                    try await self.downloadWhisper()
                case .voice:
                    try await self.provisionVoice()
                }
                self.detail[c]=nil
            } catch is CancellationError {
            } catch { self.failure[c]=error.localizedDescription }
            self.progress[c]=nil;self.tasks[c]=nil
        }
    }

    private func downloadWhisper() async throws {
        let destination=RuntimePaths.current.whisperModel
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        detail[.recognition]="Downloading whisper large-v3-turbo (574 MB)"
        let file=try await Downloader.fetch(Self.whisperURL) { [weak self] fraction in self?.progress[.recognition]=fraction }
        defer { try? FileManager.default.removeItem(at:file) }
        detail[.recognition]="Verifying the download"
        guard try await Downloader.sha256(of:file)==Self.whisperSHA256 else {
            throw JarvisError.message("The speech model failed its integrity check and was discarded. Try again.")
        }
        try? FileManager.default.removeItem(at:destination)
        try FileManager.default.moveItem(at:file,to:destination)
    }

    /// Runs the bundled voice-pack script into the active runtime folder, surfacing its
    /// STEP lines as progress. It installs Python packages and weights only; nothing is
    /// executed with elevated rights.
    private func provisionVoice() async throws {
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("provision-voice.sh")
        let script=[bundled,Configuration.project.appendingPathComponent("scripts/provision-voice.sh")].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath:$0.path) }
        guard let script else { throw JarvisError.message("The voice installer is missing from this copy of Jarvis.") }
        let root=RuntimePaths.current.root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let steps=4.0
        var step=0.0
        var lastError:String?
        let status=try await Downloader.runScript(script,arguments:[root.path]) { [weak self] line in
            if line.hasPrefix("STEP ") { step+=1;self?.progress[.voice]=step/steps;self?.detail[.voice]=String(line.dropFirst(5)) }
            if line.hasPrefix("ERROR ") { lastError=String(line.dropFirst(6)) }
        }
        guard status==0 else { throw JarvisError.message(lastError ?? "The voice pack did not install. See Console for details.") }
    }
}

/// Download, hash and script helpers kept off the main actor.
enum Downloader {
    static func fetch(_ url:URL,progress:@escaping @MainActor (Double)->Void) async throws -> URL {
        let holder=ObservationHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task=URLSession.shared.downloadTask(with:url) { temporary,response,error in
                    holder.observation=nil
                    if let error { continuation.resume(throwing:error);return }
                    guard let temporary,(response as? HTTPURLResponse)?.statusCode==200 else {
                        continuation.resume(throwing:JarvisError.message("The download server refused the request."));return
                    }
                    // The system deletes the temporary file when this handler returns.
                    let kept=FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at:temporary,to:kept);continuation.resume(returning:kept) }
                    catch { continuation.resume(throwing:error) }
                }
                holder.task=task
                holder.observation=task.progress.observe(\.fractionCompleted) { p,_ in
                    let value=p.fractionCompleted
                    Task { @MainActor in progress(value) }
                }
                task.resume()
            }
        } onCancel: { holder.task?.cancel() }
    }

    static func sha256(of file:URL) async throws -> String {
        try await Task.detached {
            let handle=try FileHandle(forReadingFrom:file);defer { try? handle.close() }
            var hasher=SHA256()
            while let chunk=try handle.read(upToCount:8<<20),!chunk.isEmpty { hasher.update(data:chunk) }
            return hasher.finalize().map { String(format:"%02x",$0) }.joined()
        }.value
    }

    static func runScript(_ script:URL,arguments:[String],line:@escaping @MainActor (String)->Void) async throws -> Int32 {
        let process=Process()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let output=Pipe()
                process.executableURL=URL(fileURLWithPath:"/bin/bash");process.arguments=[script.path]+arguments
                process.standardOutput=output;process.standardError=output
                output.fileHandleForReading.readabilityHandler={ handle in
                    let data=handle.availableData
                    guard !data.isEmpty else { handle.readabilityHandler=nil;return }
                    for text in String(decoding:data,as:UTF8.self).split(separator:"\n") {
                        let value=String(text);Task { @MainActor in line(value) }
                    }
                }
                process.terminationHandler={ p in continuation.resume(returning:p.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing:error) }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}

private final class ObservationHolder:@unchecked Sendable {
    var task:URLSessionDownloadTask?
    var observation:NSKeyValueObservation?
}

struct SetupView:View {
    @Bindable var assistant:Assistant
    let setup:SetupModel

    var body:some View {
        Form {
            Section {
                Text("Everything Jarvis needs runs on this Mac. Downloads come from Ollama and Hugging Face, are stored under Application Support, and are only started by you.")
                    .font(JarvisTypography.font(.regular,style:.callout)).foregroundStyle(JarvisTheme.secondary)
            }
            Section("Required") {
                row(.service,"Runs the language model on a private loopback port. Uses your Ollama installation's engine; Jarvis starts its own server.",action:RuntimePaths.current.ollama == nil ? "Get Ollama" : "Check again",size:nil)
                row(.everyday,"\(Configuration.everyday) · used for every conversation.",action:"Download",size:"6.6 GB")
            }
            Section("Recommended") {
                row(.recognition,"whisper.cpp large-v3-turbo · turns your voice into text on this Mac.",action:"Download",size:"574 MB")
                row(.voice,"Kokoro voice and the wake-word detector. Without it Jarvis speaks with the built-in macOS voice. Needs uv (brew install uv).",action:"Install",size:"about 2 GB")
            }
            Section("Optional") {
                row(.deep,"\(Configuration.deep) · slower, for hard questions and planning. Runs only on external power.",action:"Download",size:"17.7 GB")
            }
            Section("Permissions") {
                Text("macOS asks the first time a feature needs one: Microphone for voice, Accessibility for media keys and computer use, Automation for dark mode, Screen Recording for screen questions.")
                    .font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(JarvisTheme.canvas).navigationTitle("Setup")
    }

    private func row(_ c:SetupModel.Component,_ description:String,action:String,size:String?) -> some View {
        let done=setup.installed(c,assistant)
        return VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.firstTextBaseline) {
                Image(systemName:done ? "checkmark.circle.fill":"circle.dashed")
                    .foregroundStyle(done ? JarvisTheme.healthy:JarvisTheme.tertiary)
                VStack(alignment:.leading,spacing:3) {
                    Text(c.rawValue).font(JarvisTypography.font(.medium,style:.body))
                    Text(description).font(JarvisTypography.font(.regular,style:.caption)).foregroundStyle(JarvisTheme.secondary)
                }
                Spacer()
                if setup.running(c) {
                    Button("Cancel") { setup.cancel(c) }
                } else if !done {
                    Button(size.map { "\(action) · \($0)" } ?? action) { setup.install(c,assistant) }
                }
            }
            if let fraction=setup.progress[c] {
                ProgressView(value:fraction) { Text(setup.detail[c] ?? "Working") }.font(.caption)
            }
            if let failure=setup.failure[c] {
                Label(failure,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(JarvisTheme.warning)
            }
        }
        .padding(.vertical,4)
    }
}
