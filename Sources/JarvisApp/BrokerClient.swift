import Foundation
import JarvisCore
@MainActor final class BrokerClient {
    private var connection:NSXPCConnection?
    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let c=NSXPCConnection(serviceName:Configuration.brokerID)
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/JarvisBroker.xpc")
        c.setCodeSigningRequirement(try CodeIdentity.requirement(at:helper))
        c.remoteObjectInterface=NSXPCInterface(with:BrokerXPCProtocol.self)
        c.invalidationHandler={ [weak self] in Task { @MainActor in self?.connection=nil } }
        c.interruptionHandler={ [weak self] in Task { @MainActor in self?.connection=nil } }
        c.resume();connection=c;return c
    }
    func request(_ r:BrokerRequest) async throws -> BrokerReply {
        let c=try connect();let data=try JSONEncoder().encode(r)
        return try await withCheckedThrowingContinuation { continuation in
            let once=ReplyOnce(continuation)
            guard let proxy=c.remoteObjectProxyWithErrorHandler({ _ in once.fail(JarvisError.message("The permission helper disconnected. Reopen Jarvis to reconnect.")) }) as? BrokerXPCProtocol else { once.fail(JarvisError.message("Permission helper unavailable."));return }
            proxy.request(data) { data in
                do { let response=try JSONDecoder().decode(BrokerReply.self,from:data)
                    if let error=response.error { throw JarvisError.message(error) };once.succeed(response)
                } catch { once.fail(error) }
            }
        }
    }
}
private final class ReplyOnce:@unchecked Sendable {
    private let lock=NSLock();private var continuation:CheckedContinuation<BrokerReply,Error>?
    init(_ continuation:CheckedContinuation<BrokerReply,Error>) { self.continuation=continuation }
    func succeed(_ value:BrokerReply) { lock.lock();let c=continuation;continuation=nil;lock.unlock();c?.resume(returning:value) }
    func fail(_ error:Error) { lock.lock();let c=continuation;continuation=nil;lock.unlock();c?.resume(throwing:error) }
}
