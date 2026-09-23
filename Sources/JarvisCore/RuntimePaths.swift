import Foundation

/// Where Jarvis's local runtimes live: the speech environment, whisper, the wake-word
/// models, and the Ollama server binary.
///
/// A development build uses the project's `.runtime`. An installed Jarvis.app has no
/// project, so Setup provisions the same layout under Application Support instead, and
/// the helper scripts ship inside the app bundle. Everything resolves here so no other
/// file has to know which of the two it is running as.
public struct RuntimePaths: Sendable {
    /// Holds venv/, whisper-cli, models/, huggingface/ and optionally ollama/.
    public let root: URL
    /// Holds worker.py and wakeword.py.
    public let scripts: URL

    public var python: URL { root.appendingPathComponent("venv/bin/python") }
    public var speechWorker: URL { scripts.appendingPathComponent("worker.py") }
    public var wakeWordScript: URL { scripts.appendingPathComponent("wakeword.py") }
    public var wakeWordModels: URL { root.appendingPathComponent("models/wakeword") }
    public var whisperCLI: URL { root.appendingPathComponent("whisper-cli") }
    /// A provisioned copy first, then the one the app bundle ships with.
    public var whisperBinary: URL? {
        [whisperCLI, Bundle.main.resourceURL?.appendingPathComponent("bin/whisper-cli")].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public var kokoro: URL { huggingFace.appendingPathComponent("hub/models--mlx-community--Kokoro-82M-bf16") }
    /// The optional voice pack: Kokoro speech and the wake-word detector share one Python environment.
    public var naturalVoiceInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: kokoro.path)
    }
    public var wakeWordInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: wakeWordModels.appendingPathComponent("hey_jarvis_v0.1.onnx").path)
    }
    public var whisperModel: URL { root.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin") }
    public var huggingFace: URL { root.appendingPathComponent("huggingface") }

    public init(root: URL, scripts: URL) { self.root = root; self.scripts = scripts }

    /// The runtime an installed app provisions for itself.
    public static var installed: URL { Configuration.support.appendingPathComponent("runtime", isDirectory: true) }

    public static var current: RuntimePaths {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("speech", isDirectory: true)
        let projectScripts = Configuration.project.appendingPathComponent("speech", isDirectory: true)
        let scripts = [bundled, projectScripts].compactMap { $0 }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("worker.py").path) } ?? projectScripts
        if let override = env["JARVIS_RUNTIME"] { return RuntimePaths(root: URL(fileURLWithPath: override), scripts: scripts) }
        let project = Configuration.project.appendingPathComponent(".runtime", isDirectory: true)
        // A provisioned install wins over a project checkout, so an app copied to
        // /Applications keeps working after the source folder moves or is deleted.
        for root in [installed, project] where fm.fileExists(atPath: root.appendingPathComponent("venv/bin/python").path) {
            return RuntimePaths(root: root, scripts: scripts)
        }
        return RuntimePaths(root: installed, scripts: scripts)
    }

    /// The Ollama server binary: a private copy if one was provisioned, otherwise the
    /// user's own installation. Jarvis always runs it as its own loopback-only server.
    public var ollama: URL? {
        let candidates = [root.appendingPathComponent("ollama/ollama").path,
                          "/Applications/Ollama.app/Contents/Resources/ollama",
                          "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
