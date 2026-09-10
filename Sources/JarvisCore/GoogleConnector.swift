import Foundation
import Network
import CryptoKit

/// Where the broker keeps credentials. Backed by the encrypted vault rather than the
/// Keychain, because an XPC service cannot create Keychain items without a user
/// interaction session (errSecInteractionNotAllowed).
public protocol CredentialStore: AnyObject {
    func credential(_ name: String) throws -> Data?
    func setCredential(_ data: Data?, for name: String) throws
}
@MainActor public final class GoogleConnector {
    private let store: CredentialStore
    public init(store: CredentialStore) { self.store = store }
    private let session=URLSession(configuration:.ephemeral)
    private var listener:NWListener?
    private var callback:CheckedContinuation<String,Error>?
    private var state=""
    public func configure(_ json:String) throws {
        guard let data=json.data(using:.utf8),let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],let installed=obj["installed"] as? [String:Any],let id=installed["client_id"] as? String,id.hasSuffix(".apps.googleusercontent.com") else { throw JarvisError.message("Choose the downloaded Google Desktop OAuth client JSON.") }
        try store.setCredential(data,for:"google-client")
    }
    private func client() throws -> [String:Any] {
        guard let data=try store.credential("google-client"),let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],let client=obj["installed"] as? [String:Any] else { throw JarvisError.message("Import a Google Desktop OAuth client JSON in Connections first.") }
        return client
    }
    private func tokenRequest(_ fields:[String:String]) async throws -> [String:Any] {
        var components=URLComponents();components.queryItems=fields.map { URLQueryItem(name:$0.key,value:$0.value) }
        var r=URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!);r.httpMethod="POST"
        r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        r.httpBody=components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B").data(using:.utf8)
        let (data,response)=try await session.data(for:r)
        guard (response as? HTTPURLResponse)?.statusCode == 200,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw JarvisError.message("Google authorization failed or expired. Reconnect in Connections.") }
        return object
    }
    public func connect(write:Bool,open:@escaping (URL)->Void) async throws {
        guard listener == nil else { throw JarvisError.message("Google sign-in is already in progress.") }
        let client=try client()
        let verifier=Data((0..<32).map { _ in UInt8.random(in:0...255) }).base64URLEncoded
        let challenge=Data(SHA256.hash(data:Data(verifier.utf8))).base64URLEncoded
        state=UUID().uuidString
        let params=NWParameters.tcp;params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let l=try NWListener(using:params);listener=l
        defer { l.cancel();listener=nil;callback=nil }
        let port:UInt16=try await withCheckedThrowingContinuation { continuation in
            // A listener can report ready and failed; claim() guarantees the continuation resumes once.
            let once=ResumeOnce()
            l.stateUpdateHandler={ value in
                if case .ready=value,let port=l.port,once.claim() { continuation.resume(returning:port.rawValue) }
                if case .failed(let error)=value,once.claim() { continuation.resume(throwing:error) }
            }
            l.newConnectionHandler={ [weak self] connection in
                guard let self else { connection.cancel();return }
                connection.start(queue:.main)
                connection.receive(minimumIncompleteLength:1,maximumLength:8192) { data,_,_,_ in
                    Task { @MainActor in
                        guard let data,let text=String(data:data,encoding:.utf8),let first=text.components(separatedBy:"\r\n").first else { connection.cancel();return }
                        let pieces=first.split(separator:" ")
                        guard pieces.count>=2,pieces[0]=="GET",let parts=URLComponents(string:"http://127.0.0.1"+pieces[1]),parts.path=="/oauth/callback" else { connection.cancel();return }
                        let items=parts.queryItems ?? []
                        guard items.first(where:{$0.name=="state"})?.value == self.state else { connection.cancel();return }
                        let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nReturn to Jarvis. You may close this window."
                        connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in connection.cancel() })
                        if let code=items.first(where:{$0.name=="code"})?.value { self.callback?.resume(returning:code) }
                        else { self.callback?.resume(throwing:JarvisError.message("Google sign-in was declined.")) }
                        self.callback=nil
                    }
                }
            }
            l.start(queue:.main)
        }
        let redirect="http://127.0.0.1:\(port)/oauth/callback"
        let scopes=write ? "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/calendar.events" : "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.events.readonly"
        var url=URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems=["client_id":client["client_id"] as! String,"redirect_uri":redirect,"response_type":"code","scope":scopes,"state":state,"code_challenge":challenge,"code_challenge_method":"S256","access_type":"offline","prompt":"consent"].map { URLQueryItem(name:$0.key,value:$0.value) }
        let code:String=try await withCheckedThrowingContinuation { continuation in
            callback=continuation;open(url.url!)
            // Tag the timer with this attempt's state so a stale timeout cannot cancel a later sign-in.
            Task { @MainActor [weak self,state] in
                try? await Task.sleep(for:.seconds(180))
                guard let self,self.state==state else { return }
                self.callback?.resume(throwing:JarvisError.message("Google sign-in timed out."));self.callback=nil
            }
        }
        var fields=["client_id":client["client_id"] as! String,"code":code,"code_verifier":verifier,"redirect_uri":redirect,"grant_type":"authorization_code"]
        if let secret=client["client_secret"] as? String { fields["client_secret"]=secret }
        var token=try await tokenRequest(fields)
        token["expires_at"]=Date().timeIntervalSince1970+(token["expires_in"] as? Double ?? 3600)
        token["write_enabled"]=write
        try store.setCredential(JSONSerialization.data(withJSONObject:token),for:"google-token")
    }
    public func disconnect() { try? store.setCredential(nil,for:"google-token");callback?.resume(throwing:CancellationError());callback=nil;listener?.cancel();listener=nil }
    public var connected:Bool { ((try? store.credential("google-token")) ?? nil) != nil }
    private func access(write:Bool) async throws -> String {
        guard let data=try store.credential("google-token"),var token=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw JarvisError.message("Connect Google in Connections first.") }
        if write && token["write_enabled"] as? Bool != true { throw JarvisError.message("Enable Google sending and calendar changes in Connections first.") }
        if (token["expires_at"] as? Double ?? 0) < Date().timeIntervalSince1970+60 {
            guard let refresh=token["refresh_token"] as? String else { throw JarvisError.message("Reconnect Google to refresh access.") }
            let client=try client();var fields=["client_id":client["client_id"] as! String,"refresh_token":refresh,"grant_type":"refresh_token"]
            if let secret=client["client_secret"] as? String { fields["client_secret"]=secret }
            let new=try await tokenRequest(fields);for (k,v) in new { token[k]=v }
            token["expires_at"]=Date().timeIntervalSince1970+(new["expires_in"] as? Double ?? 3600)
            try store.setCredential(JSONSerialization.data(withJSONObject:token),for:"google-token")
        }
        guard let access=token["access_token"] as? String else { throw JarvisError.message("Reconnect Google.") };return access
    }
    public func request(path:String,query:[String:String]=[:],body:[String:Any]?=nil,method:String="GET") async throws -> [String:Any] {
        // All paths originate in fixed broker operations; the model cannot supply a host.
        let token=try await access(write:method != "GET")
        var c=URLComponents(string:"https://www.googleapis.com"+path)!
        c.queryItems=query.map { URLQueryItem(name:$0.key,value:$0.value) }
        var r=URLRequest(url:c.url!);r.httpMethod=method;r.timeoutInterval=30
        r.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        if let body { r.httpBody=try JSONSerialization.data(withJSONObject:body);r.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await session.data(for:r)
        guard let status=(response as? HTTPURLResponse)?.statusCode,(200..<300).contains(status) else { throw JarvisError.message("Google request failed. Check permissions and connection status.") }
        return (try JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }
}
final class ResumeOnce:@unchecked Sendable {
    private let lock=NSLock();private var done=false
    func claim()->Bool { lock.lock();defer { lock.unlock() };if done { return false };done=true;return true }
}
extension Data {
    public var base64URLEncoded:String { base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
}
