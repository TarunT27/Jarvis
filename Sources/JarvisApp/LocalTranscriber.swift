import Foundation
import JarvisCore

/// Speech-to-text with whisper.cpp, run directly rather than through the Python worker,
/// so recognition works on an installed Jarvis with no Python environment at all.
///
/// The language routing is the one measured in STATUS.md and kept in speech/worker.py:
/// English decodes as English; an explicit Telugu choice adds a Telugu-script prompt;
/// `auto` first collapses detection to English-or-Telugu (whisper's own auto-detect
/// labels Telugu as Tamil), then decodes without the prompt because the utterance may
/// be code-switched.
enum LocalTranscriber {
    private static let teluguPrompt="ఇది తెలుగు సంభాషణ. అన్ని పదాలు తెలుగు లిపిలో రాయాలి."

    static var available:Bool {
        let paths=RuntimePaths.current
        return paths.whisperBinary != nil && FileManager.default.fileExists(atPath:paths.whisperModel.path)
    }

    static func transcribe(_ wav:Data,language:String) async throws -> (text:String,language:String) {
        let paths=RuntimePaths.current
        guard let binary=paths.whisperBinary,FileManager.default.fileExists(atPath:paths.whisperModel.path) else {
            throw JarvisError.message("Speech recognition is not installed. Open Setup to download it.")
        }
        guard wav.count<=8_000_000 else { throw JarvisError.message("Recording is too long.") }
        guard ["auto","en","te"].contains(language) else { throw JarvisError.message("Unsupported language.") }
        let base=["-m",paths.whisperModel.path,"-f","-","-nt","-t","4"]
        var chosen=language
        if language=="auto" {
            let detection=try await run(binary,base+["-dl"],input:wav)
            let found=detection.error.range(of:"auto-detected language: ([a-z]{2})",options:.regularExpression)
                .map { String(detection.error[$0].suffix(2)) }
            chosen=found=="en" ? "en":"te"
        }
        let routing=chosen=="te" && language=="te" ? ["-l","te","--prompt",teluguPrompt] : ["-l",chosen]
        let result=try await run(binary,base+["-otxt","-of","-"]+routing,input:wav)
        guard result.status==0 else { throw JarvisError.message("Local transcription failed.") }
        return (result.output.trimmingCharacters(in:.whitespacesAndNewlines),chosen)
    }

    private struct Output { var status:Int32; var output:String; var error:String }

    /// Feeds stdin from its own thread: whisper reads all of it before writing anything,
    /// and a recording is far larger than a pipe buffer, so a single thread would deadlock.
    private static func run(_ binary:URL,_ arguments:[String],input:Data) async throws -> Output {
        let process=Process()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let stdin=Pipe(),stdout=Pipe(),stderr=Pipe()
                    process.executableURL=binary;process.arguments=arguments
                    process.standardInput=stdin;process.standardOutput=stdout;process.standardError=stderr
                    do { try process.run() } catch { continuation.resume(throwing:error);return }
                    DispatchQueue.global().async {
                        try? stdin.fileHandleForWriting.write(contentsOf:input)
                        try? stdin.fileHandleForWriting.close()
                    }
                    var errorData=Data()
                    let errorReader=DispatchQueue(label:"local.jarvis.whisper.stderr")
                    let group=DispatchGroup();group.enter()
                    errorReader.async { errorData=stderr.fileHandleForReading.readDataToEndOfFile();group.leave() }
                    let outputData=stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit();group.wait()
                    if process.terminationReason == .uncaughtSignal { continuation.resume(throwing:CancellationError());return }
                    continuation.resume(returning:Output(status:process.terminationStatus,output:String(decoding:outputData,as:UTF8.self),
                                                         error:String(decoding:errorData,as:UTF8.self)))
                }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}
