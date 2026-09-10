import Foundation
import JarvisCore
import IOKit.ps
@MainActor final class LocalRuntime {
    private var server:Process?
    func start() async throws {
        if (try? await ModelClient().installed()) != nil { return }
        let p=Process(); p.executableURL=Configuration.project.appendingPathComponent(".runtime/ollama/ollama");p.arguments=["serve"]
        var env=ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"]="127.0.0.1:11439";env["OLLAMA_NO_CLOUD"]="1";env["OLLAMA_MODELS"]=Configuration.modelStore.path
        env["OLLAMA_CONTEXT_LENGTH"]="8192";env["OLLAMA_MAX_LOADED_MODELS"]="1";env["OLLAMA_NUM_PARALLEL"]="1";env["OLLAMA_KEEP_ALIVE"]="5m"
        p.environment=env;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();server=p
        for _ in 0..<40 {
            try await Task.sleep(for:.milliseconds(500))
            if (try? await ModelClient().installed()) != nil { return }
        }
        throw JarvisError.message("Local model service did not start. Run the setup script again.")
    }
    static var onBattery: Bool {
        guard let info=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),let type=IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
    func stop() { if server?.isRunning == true { server?.terminate() };server=nil }
}
