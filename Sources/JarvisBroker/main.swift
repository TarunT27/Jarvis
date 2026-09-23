import Foundation
import OSLog
import JarvisCore

// Status only: connection accept/reject and startup faults. Never arguments,
// file contents, tokens or message bodies - those must not reach the log.
let log = Logger(subsystem: Configuration.appID, category: "broker")
final class Delegate:NSObject,NSXPCListenerDelegate {
    static let shared: BrokerService = {
        if Thread.isMainThread { return MainActor.assumeIsolated { BrokerService() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { BrokerService() } }
    }()
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        guard connection.effectiveUserIdentifier==getuid() else { log.error("rejected connection from another user");return false }
        var app=Bundle.main.bundleURL
        for _ in 0..<3 { app.deleteLastPathComponent() }
        let requirement:String
        do { requirement=try CodeIdentity.requirement(at:app) }
        catch { log.error("rejected connection: cannot pin app identity at \(app.path, privacy: .public): \(error.localizedDescription, privacy: .public)");return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface=NSXPCInterface(with:BrokerXPCProtocol.self)
        // One service for the whole process. A second instance would open a second Vault
        // on the same vault.enc, and because save() rewrites the file whole, the two would
        // silently overwrite each other's memories, settings and outbox records.
        connection.exportedObject=Delegate.shared
        connection.resume();log.info("accepted connection from pinned app");return true
    }
}
// Offline introspection for the benchmark harness: prints the exact tool catalog the
// policy enforces, so tests can never drift from what the broker actually accepts.
if CommandLine.arguments.contains("--dump-tools") {
    let payload:[String:Any]=["tools":ToolCatalog.definitions,"required":ActionPolicy.allowed.mapValues { $0.sorted() },"reads":ActionPolicy.reads.sorted(),"instant":ActionPolicy.instant.sorted()]
    let data=try! JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
}
let delegate=Delegate()
let listener=NSXPCListener.service()
listener.delegate=delegate
listener.resume()
