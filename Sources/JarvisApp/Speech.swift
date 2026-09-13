import Foundation
import AVFoundation
import AVFAudio
import CoreAudio
import JarvisCore
import Carbon

final class SpeechWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var remainder = Data()
    private var inFlight = false
    private let queue = DispatchQueue(label:"local.jarvis.speech")
    func cancel() {
        lock.lock(); let p = inFlight ? process : nil
        if inFlight { process=nil; input=nil; output=nil }; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
    func request(_ body: [String:String]) async throws -> [String:Any] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        self.lock.lock()
                        self.inFlight = true
                        if self.process?.isRunning != true {
                            let p=Process(), i=Pipe(), o=Pipe()
                            p.executableURL=Configuration.project.appendingPathComponent(".runtime/venv/bin/python")
                            p.arguments=[Configuration.project.appendingPathComponent("speech/worker.py").path]
                            p.standardInput=i; p.standardOutput=o; p.standardError=FileHandle.nullDevice
                            do { try p.run() } catch { self.inFlight=false; self.lock.unlock(); throw error }; self.process=p; self.input=i.fileHandleForWriting; self.output=o.fileHandleForReading; self.remainder=Data()
                        }
                        let i=self.input!, o=self.output!
                        self.lock.unlock()
                        defer { self.lock.lock();self.inFlight=false;self.lock.unlock() }
                        var data=try JSONSerialization.data(withJSONObject:body); data.append(10)
                        try i.write(contentsOf:data)
                        while self.remainder.firstIndex(of:10) == nil {
                            let d=o.availableData
                            guard !d.isEmpty else { throw CancellationError() }
                            self.remainder.append(d)
                            guard self.remainder.count < 40_000_000 else { throw JarvisError.message("Speech response is too large.") }
                        }
                        let split=self.remainder.firstIndex(of:10)!
                        let line=self.remainder.prefix(upTo:split); self.remainder.removeSubrange(...split)
                        let result=try JSONSerialization.jsonObject(with:line) as! [String:Any]
                        if let error=result["error"] as? String { throw JarvisError.message(error) }
                        continuation.resume(returning:result)
                    } catch { continuation.resume(throwing:error) }
                }
            }
        },onCancel:{ self.cancel() })
    }
}
final class SampleBuffer: @unchecked Sendable {
    /// Audio past this point is dropped on the floor. A held session must end here too,
    /// or the interface would go on saying "listening" while nothing is being kept.
    static let retentionSeconds: Double = 90
    let lock=NSLock(); var samples=[Float](); var sampleRate: Double=48000; private var rms:Float=0
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel=buffer.floatChannelData?[0] else { return }
        lock.lock(); defer { lock.unlock() }
        sampleRate=buffer.format.sampleRate
        let count=Int(buffer.frameLength)
        if count > 0 {
            var sum:Float=0
            for sample in UnsafeBufferPointer(start:channel,count:count) { sum += sample * sample }
            let frameRMS=sqrt(sum / Float(count))
            rms=max(frameRMS,rms * 0.82)
        }
        if samples.count < Int(sampleRate * SampleBuffer.retentionSeconds) { samples.append(contentsOf:UnsafeBufferPointer(start:channel,count:count)) }
    }
    var level:Float { lock.lock(); defer { lock.unlock() }; return rms }
    func take() -> ([Float],Double) { lock.lock(); defer { lock.unlock() }; let s=samples; samples=[]; rms=0; return(s,sampleRate) }
}
@MainActor final class VoiceController {
    private var engine: AVAudioEngine?
    private let buffer=SampleBuffer()
    private var player: AVAudioPlayer?
    var onFinished: (() -> Void)?
    var level:Float { buffer.level }
    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
    /// True from the moment a session begins until it is captured or discarded. It stays
    /// true while the session is paused, when no engine is running at all.
    private(set) var sessionActive=false

    func start() async throws {
        stopPlayback()
        guard await requestPermission() else { throw JarvisError.message("Microphone access is off. Enable Jarvis in System Settings → Privacy & Security → Microphone.") }
        _=buffer.take()
        try startEngine()
        sessionActive=true
    }

    /// Stops the hardware and keeps everything captured so far. The macOS recording
    /// indicator goes out, which is the honest signal: while paused, nothing is heard.
    func pause() { teardownEngine() }

    /// Restarts the hardware on an existing session, appending to what is already held.
    func resume() throws { try startEngine() }

    var isCapturing: Bool { engine != nil }

    private func startEngine() throws {
        let e=AVAudioEngine(); let node=e.inputNode
        // inputFormat, not outputFormat. outputFormat(forBus:) reports the format the node
        // hands downstream, which follows the OUTPUT device. On a Bluetooth headset the two
        // disagree - AirPods run their microphone at 24 kHz in hands-free mode while the
        // output chain stays at 48 kHz - and a tap installed with the wrong format is handed
        // silence, with no error anywhere. Passing nil below lets the engine supply the
        // node's own format, so this cannot drift apart again.
        let format=node.inputFormat(forBus:0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw JarvisError.message("No microphone is available. Check System Settings → Sound → Input.")
        }
        node.installTap(onBus:0,bufferSize:2048,format:nil) { [buffer] b,_ in buffer.append(b) }
        e.prepare(); try e.start(); engine=e
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus:0); engine.stop(); self.engine=nil
    }
    /// Why a recording produced nothing, so the status line can say something useful
    /// instead of "No speech detected" for four different causes.
    enum CaptureOutcome {
        case audio(Data)
        case notRecording
        case tooShort
        case silent(device: String?)
    }
    /// The default input device's name, for a failure message that can be acted on.
    static func defaultInputName() -> String? {
        var device=AudioDeviceID(0)
        var size=UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope:kAudioObjectPropertyScopeGlobal,
                                                     mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&deviceAddress,0,nil,&size,&device)==noErr else { return nil }
        var name:Unmanaged<CFString>?
        var nameSize=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,
                                                   mScope:kAudioObjectPropertyScopeGlobal,
                                                   mElement:kAudioObjectPropertyElementMain)
        let status=withUnsafeMutablePointer(to:&name) {
            AudioObjectGetPropertyData(device,&nameAddress,0,nil,&nameSize,$0)
        }
        guard status==noErr, let value=name?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }
    func capture() -> CaptureOutcome {
        guard sessionActive else { return .notRecording }
        sessionActive=false
        teardownEngine()
        let (samples,rate)=buffer.take()
        guard samples.count > Int(rate*0.2) else { return .tooShort }
        guard samples.contains(where:{ abs($0)>0.012 }) else { return .silent(device:Self.defaultInputName()) }
        // Resample mono capture to 16 kHz PCM WAV entirely in RAM.
        let count=Int(Double(samples.count)*16000/rate)
        var pcm=Data(capacity:count*2)
        for index in 0..<count {
            let position=Double(index)*rate/16000; let lo=Int(position); let hi=min(lo+1,samples.count-1); let f=Float(position-Double(lo))
            let sample=samples[lo]*(1-f)+samples[hi]*f
            var value=Int16(max(-1,min(1,sample))*32767).littleEndian
            withUnsafeBytes(of:&value) { pcm.append(contentsOf:$0) }
        }
        var wav=Data()
        func text(_ s:String) { wav.append(Data(s.utf8)) }
        func u32(_ n:UInt32) { var v=n.littleEndian; withUnsafeBytes(of:&v) { wav.append(contentsOf:$0) } }
        func u16(_ n:UInt16) { var v=n.littleEndian; withUnsafeBytes(of:&v) { wav.append(contentsOf:$0) } }
        text("RIFF");u32(UInt32(36+pcm.count));text("WAVEfmt ");u32(16);u16(1);u16(1);u32(16000);u32(32000);u16(2);u16(16);text("data");u32(UInt32(pcm.count));wav.append(pcm)
        return .audio(wav)
    }
    /// Ends a session and throws its audio away without transcribing it.
    func discard() { sessionActive=false; teardownEngine(); _=buffer.take() }
    func play(_ data:Data) throws { player=try AVAudioPlayer(data:data); player?.play() }
    var isPlaying:Bool { player?.isPlaying == true }
    func stopPlayback() { player?.stop();player=nil }
    func cancel() { discard();stopPlayback() }
}
@MainActor final class PushToTalkShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?; var onRelease: (() -> Void)?
    init() {
        var events=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        let ptr=Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,data in
            guard let event,let data else { return OSStatus(eventNotHandledErr) }
            let pressed=GetEventKind(event)==UInt32(kEventHotKeyPressed)
            let shortcut=Unmanaged<PushToTalkShortcut>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in if pressed { shortcut.onPress?() } else { shortcut.onRelease?() } }
            return noErr
        },2,&events,ptr,&handler)
        register(key:49,modifiers:UInt32(controlKey|optionKey))
    }
    func register(key:UInt32,modifiers:UInt32) {
        if let reference { UnregisterEventHotKey(reference) }
        RegisterEventHotKey(key,modifiers,EventHotKeyID(signature:0x4A415256,id:1),GetApplicationEventTarget(),0,&reference)
    }
}
