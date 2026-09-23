import Foundation
import AVFoundation
import JarvisCore

/// Listens for "Hey Jarvis" and nothing else. Audio is converted to 16 kHz PCM in
/// memory and streamed over a pipe to the local detector, which only scores it
/// against the phrase. It is stopped whenever a conversation owns the microphone.
@MainActor final class WakeWordListener {
    var onWake:(()->Void)?
    var onFailure:((String)->Void)?
    private var engine:AVAudioEngine?
    private var process:Process?
    private let feed=DispatchQueue(label:"local.jarvis.wakeword")
    var isRunning:Bool { engine != nil }

    func start() throws {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else {
            throw JarvisError.message("Hey Jarvis needs microphone access. Enable Jarvis in System Settings › Privacy & Security › Microphone.")
        }
        let paths=RuntimePaths.current
        guard FileManager.default.isExecutableFile(atPath:paths.python.path),FileManager.default.fileExists(atPath:paths.wakeWordScript.path) else {
            throw JarvisError.message("The wake-word engine is not installed. Open Setup to install it.")
        }
        let p=Process(),input=Pipe(),output=Pipe()
        p.executableURL=paths.python;p.arguments=[paths.wakeWordScript.path]
        var env=ProcessInfo.processInfo.environment
        env["JARVIS_WAKEWORD_MODELS"]=paths.wakeWordModels.path
        p.environment=env
        p.standardInput=input;p.standardOutput=output;p.standardError=FileHandle.nullDevice
        try p.run();process=p
        let writer=input.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler=nil;return }
            for line in data.split(separator:10) {
                guard let json=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { continue }
                let error=json["error"] as? String
                let woke=json["wake"] != nil
                Task { @MainActor in
                    if woke { self?.onWake?() }
                    if let error { self?.stop();self?.onFailure?("Hey Jarvis stopped: \(error)") }
                }
            }
        }

        let e=AVAudioEngine(),node=e.inputNode
        let format=node.inputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0,
              let target=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true),
              let converter=AVAudioConverter(from:format,to:target) else {
            stop();throw JarvisError.message("No microphone is available for Hey Jarvis.")
        }
        let feed=self.feed
        node.installTap(onBus:0,bufferSize:4096,format:format) { buffer,_ in
            let capacity=AVAudioFrameCount(Double(buffer.frameLength)*16000/format.sampleRate)+32
            guard let out=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else { return }
            var consumed=false
            _=converter.convert(to:out,error:nil) { _,status in
                if consumed { status.pointee = .noDataNow;return nil }
                consumed=true;status.pointee = .haveData;return buffer
            }
            guard out.frameLength>0,let samples=out.int16ChannelData?[0] else { return }
            let data=Data(bytes:samples,count:Int(out.frameLength)*2)
            // A detector that has died must not take the audio thread down with it.
            feed.async { try? writer.write(contentsOf:data) }
        }
        e.prepare()
        do { try e.start() } catch { stop();throw error }
        engine=e
    }

    func stop() {
        if let engine { engine.inputNode.removeTap(onBus:0);engine.stop() }
        engine=nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler=nil
        if process?.isRunning == true { process?.terminate() }
        process=nil
    }
}
