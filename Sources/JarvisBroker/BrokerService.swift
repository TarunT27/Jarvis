import Foundation
import OSLog
import CryptoKit
import AppKit
import PDFKit
import EventKit
import JarvisCore

@MainActor final class BrokerService:NSObject,BrokerXPCProtocol {
    private var vault:Vault?
    private var startupError:String?
    private let policy=ActionPolicy()
    private var google:GoogleConnector?
    private var roots:[URL]=[]
    private var apps:Set<String>=["com.apple.finder","com.apple.Safari","com.apple.TextEdit","com.apple.Notes","com.apple.reminders","com.apple.iCal"]
    private var active:Set<UUID>=[]
    private var taskConversations:[UUID:UUID]=[:]
    private let privacy=PrivacyLedger()
    private let store=EKEventStore()
    private let computer=NativeComputerController()
    private let system=SystemController()
    private let computerSessions=ComputerSessionPolicy()
    private var computerExpiry:Task<Void,Never>?

    private func endComputerSession(taskID:UUID?=nil) {
        guard let ended=computerSessions.stop(taskID:taskID) else { return }
        computer.stop();computerExpiry?.cancel();computerExpiry=nil
        policy.revokeComputerApprovals(taskID:ended.taskID)
    }
    private func expireComputerSession() {
        if let ended=computerSessions.expireIfNeeded() {
            computer.stop();computerExpiry?.cancel();computerExpiry=nil
            policy.revokeComputerApprovals(taskID:ended.taskID)
        }
    }
    private func computerSession(task:UUID) throws -> ComputerSession {
        expireComputerSession()
        guard let session=computerSessions.session,session.taskID==task,active.contains(task) else {
            throw JarvisError.message("Start an explicit computer task for a selected app first.")
        }
        return session
    }

    /// Opens the encrypted vault with the root key the app read from the Keychain.
    /// The key is held in memory for the life of this service and never written to disk.
    private func open(_ key:SymmetricKey) throws {
        do {
            let opened=try Vault(url:Configuration.support.appendingPathComponent("vault.enc"),key:key)
            for row in try opened.rows(kind:"settings") {
                if row["id"]=="roots",let data=row["body"]?.data(using:.utf8),let paths=try JSONSerialization.jsonObject(with:data) as? [String] { roots=paths.map { URL(fileURLWithPath:$0) } }
                if row["id"]=="apps",let data=row["body"]?.data(using:.utf8),let ids=try JSONSerialization.jsonObject(with:data) as? [String] { apps=Set(ids) }
            }
            vault=opened;google=GoogleConnector(store:opened);startupError=nil
            log.info("vault opened")
        } catch {
            startupError=error.localizedDescription
            log.error("could not open vault: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    private func ready() throws -> (Vault,GoogleConnector) {
        guard let vault,let google else { throw JarvisError.message(startupError ?? "Jarvis is still starting up. Reopen the app if this persists.") }
        return (vault,google)
    }
    nonisolated func request(_ data:Data,withReply reply:@escaping (Data)->Void) {
        Task { @MainActor in
            let response:BrokerReply
            do {
                guard data.count<1_000_000 else { throw JarvisError.message("Request exceeds size limit.") }
                if let startupError=self.startupError { throw JarvisError.message(startupError) }
                response=try await self.handle(JSONDecoder().decode(BrokerRequest.self,from:data))
                try? self.vault?.flush()
            } catch { response=BrokerReply(error:error.localizedDescription) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    private func json(_ value:Any) throws -> String { String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)! }
    private func persistRoots() throws { try vault!.put(kind:"settings",body:json(roots.map(\.path)),id:"roots") }
    private func handle(_ r:BrokerRequest) async throws -> BrokerReply {
        if r.operation=="unlock" {
            guard let value=r.value,let raw=Data(base64Encoded:value),raw.count==32 else { throw JarvisError.message("Invalid vault key.") }
            if vault==nil { try open(SymmetricKey(data:raw)) }
            return BrokerReply(result:"Unlocked")
        }
        let (vault,google)=try ready()
        expireComputerSession()
        switch r.operation {
        case "computer_permissions":
            return BrokerReply(result:try json(NativeComputerController.permissions(prompt:r.value=="prompt")))
        case "computer_start":
            guard let id=r.taskID,active.contains(id),let bundleID=r.value,apps.contains(bundleID) else {
                throw JarvisError.message("Start a task and choose an approved application.")
            }
            try markPrivate(task:id)
            let session=try computerSessions.start(taskID:id,bundleID:bundleID)
            do {
                let name=try await computer.start(bundleID:bundleID)
                guard computerSessions.isActive(taskID:id,sessionID:session.id),active.contains(id) else { throw CancellationError() }
                computerExpiry=Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(300)) } catch { return }
                    guard let self,self.computerSessions.isActive(taskID:id,sessionID:session.id) else { self?.expireComputerSession();return }
                    self.endComputerSession(taskID:id)
                }
                return BrokerReply(result:name)
            } catch { endComputerSession(taskID:id);throw error }
        case "computer_stop":
            guard let id=r.taskID else { throw JarvisError.message("Missing computer task.") }
            endComputerSession(taskID:id);return BrokerReply(result:"Computer control stopped")
        case "computer_status":
            if let session=computerSessions.session { return BrokerReply(result:String(decoding:try JSONEncoder().encode(session),as:UTF8.self)) }
            return BrokerReply(result:"null")
        case "status": return BrokerReply(result:try json(["google":google.connected,"brave":((try? vault.credential("brave-key")) ?? nil) != nil,"folders":roots.map(\.path),"apps":apps.sorted()]))
        case "begin":
            guard let id=r.taskID,let conversation=r.conversationID else { throw JarvisError.message("Missing task.") }
            // Legacy chats lack provenance, so resumed legacy content fails closed.
            let history=try vault.rows(kind:"chat").compactMap { row -> ChatMessage? in
                guard let body=row["body"] else { return nil }
                return try? JSONDecoder().decode(ChatMessage.self,from:Data(body.utf8))
            }.filter { $0.conversationID==conversation }
            let storedMemories = try vault.rows(kind:"memory",limit:1)
            let hasMemories = r.value != "no_memory" && !storedMemories.isEmpty
            let wasPrivate = try ConversationPrivacy.isPrivate(conversation,in:vault)
            let isPrivate = r.value=="private" || hasMemories || history.contains { $0.privateContext != false } || wasPrivate
            if isPrivate { try ConversationPrivacy.mark(conversation,in:vault) }
            policy.begin(id);active.insert(id);taskConversations[id]=conversation
            // Attached screen contents are private too, and the broker never sees the image.
            privacy.begin(task:id,conversation:conversation,carriesPrivateContent:isPrivate)
            return BrokerReply(result:try json(["web_allowed":privacy.webAllowed(conversation:conversation)]))
        // Ending a task must NOT clear the taint: the conversation continues.
        case "end": if let id=r.taskID { endComputerSession(taskID:id);policy.end(id);active.remove(id);privacy.endTask(id);taskConversations.removeValue(forKey:id) };return BrokerReply(result:"Ended")
        case "cancel": endComputerSession();policy.cancelAll();active.removeAll();privacy.forgetTasks();taskConversations.removeAll();return BrokerReply(result:"Stopped")
        case "propose":
            guard let call=r.call,let id=r.taskID,active.contains(id) else { throw JarvisError.message("Task is no longer active.") }
            var computerSessionID:UUID?
            if ComputerToolCatalog.isComputerTool(call.name) {
                computerSessionID=try computerSession(task:id).id
                try markPrivate(task:id)
            } else if computerSessions.session != nil {
                throw JarvisError.message("Only supervised computer tools are available while a computer session is active.")
            }
            if call.name=="web_search" {
                guard let conversation=taskConversations[id],privacy.webAllowed(task:id),
                      try !ConversationPrivacy.isPrivate(conversation,in:vault) else {
                    throw JarvisError.message("This conversation contains private context. Turn off Include saved memories in response settings and start a new conversation for public web search.")
                }
            }
            let deadline=ComputerToolCatalog.mutating.contains(call.name) ? try computer.approvalDeadline(for:call):nil
            if let proposal=try policy.propose(call,taskID:id,computerSessionID:computerSessionID,expiresAt:deadline) { return BrokerReply(proposal:proposal) }
            return try await run(call,task:id)
        case "approve":
            guard let proposal=r.proposal else { throw JarvisError.message("Missing approval.") }
            if ComputerToolCatalog.isComputerTool(proposal.call.name) {
                guard let sessionID=proposal.computerSessionID else { throw JarvisError.message("Missing computer session approval.") }
                _=try computerSessions.validateApproval(taskID:proposal.taskID,sessionID:sessionID)
            } else if computerSessions.session != nil { throw JarvisError.message("Other actions are paused during computer use.") }
            let call=try policy.consume(proposal)
            return try await run(call,task:proposal.taskID,actionID:proposal.id)
        case "workspace_list":
            return BrokerReply(result:String(decoding:try JSONEncoder().encode(WorkspaceStore.list(vault)),as:UTF8.self))
        case "workspace_save":
            guard let value=r.value else { throw JarvisError.message("Missing workspace item.") }
            try WorkspaceStore.save(JSONDecoder().decode(WorkspaceItem.self,from:Data(value.utf8)),in:vault)
            return BrokerReply(result:"Saved locally")
        case "workspace_delete":
            guard let value=r.value,let id=UUID(uuidString:value) else { throw JarvisError.message("Invalid workspace identifier.") }
            try WorkspaceStore.delete(id,from:vault);return BrokerReply(result:"Deleted")
        case "records":
            guard let kind=r.value,["chat","memory","draft","audit","organization"].contains(kind) else { throw JarvisError.message("Collection is not available to the app.") }
            let rows=try vault.rows(kind:kind)
            if kind=="memory",!rows.isEmpty,let task=r.taskID { try markPrivate(task:task) }
            return BrokerReply(result:try json(rows))
        case "organization_save":
            guard let value=r.value,!value.isEmpty else { throw JarvisError.message("Organization data is empty.") }
            try vault.put(kind:"organization",body:value,id:"organization")
            return BrokerReply(result:"Organization saved")
        case "chat":
            guard let value=r.value else { throw JarvisError.message("Missing message.") }
            try vault.prune();try vault.put(kind:"chat",body:value);return BrokerReply(result:"Saved")
        case "memory":
            guard let text=r.value,!text.isEmpty else { throw JarvisError.message("Memory is empty.") }
            try vault.put(kind:"memory",body:text);return BrokerReply(result:"Memory saved")
        case "delete_record":
            guard let id=r.value,let row=try vault.rows().first(where:{$0["id"]==id}),["memory","draft","chat"].contains(row["kind"] ?? "") else { throw JarvisError.message("Record unavailable.") }
            try vault.delete(id:id);return BrokerReply(result:"Deleted")
        case "clear":
            guard ["chat","memory","draft","document"].contains(r.value ?? "") else { throw JarvisError.message("Unknown collection.") }
            try vault.clear(kind:r.value);return BrokerReply(result:"Cleared")
        case "add_folder":
            guard let path=r.value else { throw JarvisError.message("No folder selected.") }
            let url=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath();var dir:ObjCBool=false
            guard FileManager.default.fileExists(atPath:url.path,isDirectory:&dir),dir.boolValue else { throw JarvisError.message("Folder is unavailable.") }
            if !roots.contains(url) { roots.append(url) };try persistRoots();return BrokerReply(result:"Folder approved. Search reads documents on demand.")
        case "remove_folder":
            roots.removeAll { $0.path==r.value };try persistRoots()
            try vault.clear(kind:"document");try vault.clear(kind:"docmeta")
            return BrokerReply(result:"Access revoked and document index cleared")
        case "allow_app":
            guard let id=r.value,NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) != nil else { throw JarvisError.message("Choose an installed application.") }
            apps.insert(id);try vault.put(kind:"settings",body:json(apps.sorted()),id:"apps");return BrokerReply(result:"Application approved")
        case "remove_app": if computerSessions.session?.bundleID==r.value { endComputerSession() };apps.remove(r.value ?? "");try vault.put(kind:"settings",body:json(apps.sorted()),id:"apps");return BrokerReply(result:"Application access revoked")
        case "brave_key": try vault.setCredential(Data((r.value ?? "").utf8),for:"brave-key");return BrokerReply(result:"Search key saved")
        case "disconnect_brave": try vault.setCredential(nil,for:"brave-key");return BrokerReply(result:"Search disconnected")
        case "google_client": try google.configure(r.value ?? "");return BrokerReply(result:"Google client imported")
        case "google_connect": try await google.connect(write:r.value=="write") { NSWorkspace.shared.open($0) };return BrokerReply(result:"Google connected")
        case "disconnect_google":google.disconnect();return BrokerReply(result:"Google disconnected locally. You can also revoke access in your Google account.")
        default:throw JarvisError.message("Unsupported broker operation.")
        }
    }
    private func markPrivate(task:UUID) throws {
        guard let conversation=taskConversations[task],let vault else { throw JarvisError.message("Task is no longer active.") }
        try ConversationPrivacy.mark(conversation,in:vault)
        privacy.markPrivate(task:task)
    }
    private func run(_ call:ToolCall,task:UUID,actionID:UUID=UUID()) async throws -> BrokerReply {
        guard active.contains(task) else { throw JarvisError.message("Task was stopped.") }
        let a=call.arguments;let (vault,google)=try ready()
        if ComputerToolCatalog.isComputerTool(call.name) {
            let session=try computerSession(task:task)
            guard apps.contains(session.bundleID) else { endComputerSession(taskID:task);throw JarvisError.message("App access was revoked.") }
            try markPrivate(task:task)
            if ComputerToolCatalog.mutating.contains(call.name) {
                _=try computerSessions.reserveAction(taskID:task,sessionID:session.id)
            }
            do {
                let observation=try await computer.execute(call)
                guard active.contains(task),computerSessions.isActive(taskID:task,sessionID:session.id) else { throw CancellationError() }
                try vault.put(kind:"audit",body:try json(["tool":call.name,"status":"completed","action_id":actionID.uuidString]))
                return BrokerReply(result:observation.text,image:observation.image)
            } catch {
                try? vault.put(kind:"audit",body:try json(["tool":call.name,"status":"stopped_or_unconfirmed","action_id":actionID.uuidString]))
                endComputerSession(taskID:task)
                throw error
            }
        }
        var result=""
        if SystemToolCatalog.isSystemTool(call.name) {
            if SystemToolCatalog.privateReads.contains(call.name) { try markPrivate(task:task) }
            result=try await system.execute(call)
            guard active.contains(task) else { throw CancellationError() }
            try vault.put(kind:"audit",body:try json(["tool":call.name,"status":"completed","action_id":actionID.uuidString]))
            return BrokerReply(result:result)
        }
        switch call.name {
        case "search_documents":
            try markPrivate(task:task)
            try DocumentIndex.refresh(vault,roots:roots)
            result=try json(DocumentIndex.search(vault,query:a["query"]!))
        case "read_document": try markPrivate(task:task);result=String(try DocumentIndex.contents(of:a["path"]!,roots:roots).prefix(18000))
        case "open_app":
            guard apps.contains(a["bundle_id"]!),let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:a["bundle_id"]!) else { throw JarvisError.message("Approve this app in Settings first.") }
            _=try await NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration());result="Application opened."
        case "save_memory":try vault.put(kind:"memory",body:a["text"]!);result="Memory saved."
        case "save_draft":try vault.put(kind:"draft",body:json(a));result="Draft saved locally. Nothing was sent."
        case "gmail_search":
            try markPrivate(task:task)
            result=try json(await google.request(path:"/gmail/v1/users/me/messages",query:["q":a["query"]!,"maxResults":"10"]))
        case "gmail_read":
            try markPrivate(task:task);let id=try safeID(a["id"]!)
            let message=try await google.request(path:"/gmail/v1/users/me/messages/"+id,query:["format":"full"])
            result=try json(["id":id,"snippet":message["snippet"] ?? "","payload":extractMail(message["payload"] as? [String:Any] ?? [:])])
        case "send_email":
            // Persist an outbox intent BEFORE network I/O. Never automatically retry an ambiguous send.
            let messageID="<\(actionID.uuidString.lowercased())@jarvis.local>"
            let mime="To: \(a["to"]!)\r\nSubject: =?UTF-8?B?\(Data(a["subject"]!.utf8).base64EncodedString())?=\r\nMessage-ID: \(messageID)\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(Data(a["body"]!.utf8).base64EncodedString())"
            let digest=callDigest(call)
            let prior=try vault.rows(kind:"outbox")
            guard !prior.contains(where:{$0["source"]==digest}) else { throw JarvisError.message("This send has already been attempted. Check Sent mail and the outbox before composing a new send; automatic resend is blocked.") }
            try vault.put(kind:"outbox",body:try json(["status":"attempting","message_id":messageID]),source:digest,id:actionID.uuidString,durable:true)
            do {
                let sent=try await google.request(path:"/gmail/v1/users/me/messages/send",body:["raw":Data(mime.utf8).base64URLEncoded],method:"POST")
                try vault.put(kind:"outbox",body:try json(["status":"sent","message_id":messageID,"gmail_id":sent["id"] ?? ""]),source:digest,id:actionID.uuidString,durable:true)
                result="Email sent."
            } catch {
                let found=try? await google.request(path:"/gmail/v1/users/me/messages",query:["q":"in:sent rfc822msgid:"+messageID,"maxResults":"1"])
                let resolved = !(found?["messages"] as? [[String:Any]] ?? []).isEmpty
                try vault.put(kind:"outbox",body:try json(["status":resolved ? "sent":"uncertain","message_id":messageID]),source:digest,id:actionID.uuidString,durable:true)
                if resolved { result="Email confirmed in Sent mail." } else { throw JarvisError.message("Send outcome is uncertain. Check Gmail Sent before sending again. Jarvis will not retry this email.") }
            }
        case "calendar_list":
            try markPrivate(task:task);result=try json(await google.request(path:"/calendar/v3/calendars/primary/events",query:["timeMin":a["start"]!,"timeMax":a["end"]!,"singleEvents":"true","orderBy":"startTime","maxResults":"30"]))
        case "calendar_create","calendar_update":
            var event:[String:Any]=["summary":a["title"]!,"start":["dateTime":a["start"]!,"timeZone":a["timezone"]!],"end":["dateTime":a["end"]!,"timeZone":a["timezone"]!],"attendees":a["attendees"]!.split(separator:",").map { ["email":$0.trimmingCharacters(in:.whitespaces)] }]
            let creating=call.name=="calendar_create"
            let id=creating ? actionID.uuidString.replacingOccurrences(of:"-",with:"").lowercased() : try safeID(a["id"]!)
            if creating { event["id"]=id }
            do {
                let response=try await google.request(path:"/calendar/v3/calendars/primary/events"+(creating ? "":"/"+id),query:["sendUpdates":"all"],body:event,method:creating ? "POST":"PATCH")
                result=try json(response)
            } catch { throw JarvisError.message("Calendar update was not confirmed. Check your calendar before repeating it. Event ID: \(id)") }
        case "create_reminder":
            guard try await store.requestFullAccessToReminders() else { throw JarvisError.message("Reminders permission was denied.") }
            guard active.contains(task) else { throw CancellationError() }
            let reminder=EKReminder(eventStore:store);reminder.title=a["title"]!;reminder.calendar=store.defaultCalendarForNewReminders()
            guard reminder.calendar != nil else { throw JarvisError.message("Create a Reminders list first.") }
            if let due=a["due"],!due.isEmpty {
                guard let date=DatePolicy.instant(due) else { throw JarvisError.message("Reminder date must be one ISO8601 timestamp with a UTC offset.") }
                reminder.dueDateComponents=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:date)
            }
            try store.save(reminder,commit:true);result="Reminder created."
        case "move_file":
            try DocumentIndex.move(from:a["source"]!,to:a["destination"]!,roots:roots);result="File moved."
        case "trash_file":
            try DocumentIndex.trash(a["path"]!,roots:roots);result="Moved to Trash."
        case "web_search":
            guard let secretData=try vault.credential("brave-key"),let key=String(data:secretData,encoding:.utf8),!key.isEmpty else { throw JarvisError.message("Add a Brave Search API key in Connections.") }
            var u=URLComponents(string:"https://api.search.brave.com/res/v1/web/search")!;u.queryItems=[URLQueryItem(name:"q",value:a["query"]!),URLQueryItem(name:"count",value:"5")]
            var request=URLRequest(url:u.url!);request.setValue(key,forHTTPHeaderField:"X-Subscription-Token");request.timeoutInterval=20
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200 else { throw JarvisError.message("Search failed. Check the API key and provider quota.") }
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            result=try json(((object?["web"] as? [String:Any])?["results"] as? [[String:Any]] ?? []).prefix(5).map { ["title":$0["title"] ?? "","url":$0["url"] ?? "","description":$0["description"] ?? ""] })
        default:throw JarvisError.message("Tool is unavailable.")
        }
        try vault.put(kind:"audit",body:try json(["tool":call.name,"status":"completed","action_id":actionID.uuidString]))
        return BrokerReply(result:result)
    }
    private func safeID(_ value:String) throws -> String { guard value.range(of:"^[A-Za-z0-9_-]{1,200}$",options:.regularExpression) != nil else { throw JarvisError.message("Invalid remote item ID.") };return value }
    private func extractMail(_ payload:[String:Any]) -> [String:Any] {
        var result:[String:Any]=[:]
        if let headers=payload["headers"] as? [[String:String]] { result["headers"]=headers.filter { ["from","to","subject","date"].contains(($0["name"] ?? "").lowercased()) } }
        if let body=payload["body"] as? [String:Any],let encoded=body["data"] as? String {
            var b64=encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");b64+=String(repeating:"=",count:(4-b64.count%4)%4)
            if let data=Data(base64Encoded:b64),let text=String(data:data,encoding:.utf8) { result["text"]=String(text.prefix(18000)) }
        }
        if let parts=payload["parts"] as? [[String:Any]] { result["parts"]=parts.prefix(8).filter { ($0["filename"] as? String ?? "").isEmpty }.map(extractMail) }
        return result
    }
}
import CryptoKit
private func callDigest(_ call:ToolCall) -> String {
    let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
    return SHA256.hash(data:try! encoder.encode(call)).map { String(format:"%02x",$0) }.joined()
}
