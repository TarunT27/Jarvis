import Foundation
import CryptoKit

public enum DatePolicy {
    /// One complete ISO8601 instant with an explicit UTC offset - nothing more.
    /// ISO8601DateFormatter parses a valid prefix and discards the rest, so an
    /// interval like "<start>/<end>" would otherwise be accepted as its first half.
    public static func instant(_ value: String) -> Date? {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(Z|[+-]\\d{2}:\\d{2})$",
                          options: .regularExpression) != nil else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
public final class ActionPolicy {
    private var pending: [UUID: ActionProposal] = [:]
    private var tasks: Set<UUID> = []
    public static let allowed: [String: Set<String>] = [
        "search_documents":["query"], "read_document":["path"], "open_app":["bundle_id"],
        "web_search":["query"], "gmail_search":["query"], "gmail_read":["id"],
        "save_draft":["to","subject","body"], "send_email":["to","subject","body"],
        "calendar_list":["start","end"], "calendar_create":["title","start","end","timezone","attendees"],
        "calendar_update":["id","title","start","end","timezone","attendees"],
        "create_reminder":["title","due"], "save_memory":["text"],
        "move_file":["source","destination"], "trash_file":["path"]
    ]
    public static let reads: Set<String> = ["search_documents","read_document","open_app","web_search","gmail_search","gmail_read","calendar_list","save_draft"]
    public init() {}
    public func begin(_ id: UUID) { tasks.insert(id) }
    public func end(_ id: UUID) { tasks.remove(id); pending = pending.filter { $0.value.taskID != id } }
    public func cancelAll() { tasks.removeAll(); pending.removeAll() }
    public func validate(_ call: ToolCall) throws {
        guard let fields = Self.allowed[call.name], Set(call.arguments.keys) == fields else { throw JarvisError.message("Unsupported tool or arguments.") }
        guard call.arguments.values.allSatisfy({ $0.utf8.count <= 16_000 && !$0.contains("\0") }) else { throw JarvisError.message("Tool arguments exceed limits.") }
        for required in fields.subtracting(["due","attendees"]) {
            guard !(call.arguments[required] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw JarvisError.message("Missing \(required).") }
        }
        if ["send_email","save_draft"].contains(call.name) {
            let to = call.arguments["to"]!
            guard !to.contains("\n"), !to.contains("\r"), !call.arguments["subject"]!.contains("\n"), !call.arguments["subject"]!.contains("\r"),
                  to.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", options:.regularExpression) != nil
            else { throw JarvisError.message("Use one explicit email address and a single-line subject.") }
        }
        if call.name == "create_reminder", let due = call.arguments["due"], !due.isEmpty, DatePolicy.instant(due) == nil {
            throw JarvisError.message("Reminder time must be one ISO8601 timestamp with a UTC offset, for example 2026-09-11T16:30:00-04:00.")
        }
        if call.name.hasPrefix("calendar_") {
            guard let start = DatePolicy.instant(call.arguments["start"] ?? ""), let end = DatePolicy.instant(call.arguments["end"] ?? ""), end > start else { throw JarvisError.message("Each of start and end must be one ISO8601 timestamp with a UTC offset, never a range; end must follow start.") }
            if let zone = call.arguments["timezone"], TimeZone(identifier:zone) == nil { throw JarvisError.message("Unknown timezone.") }
            if let attendees = call.arguments["attendees"], !attendees.isEmpty {
                for address in attendees.split(separator:",") { guard address.trimmingCharacters(in:.whitespaces).range(of:"^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$",options:.regularExpression) != nil else { throw JarvisError.message("Invalid attendee address.") } }
            }
        }
    }
    public func propose(_ call: ToolCall, taskID: UUID, now: Date = Date()) throws -> ActionProposal? {
        guard tasks.contains(taskID) else { throw JarvisError.message("This task is no longer active.") }
        try validate(call)
        if Self.reads.contains(call.name) { return nil }
        let proposal = ActionProposal(id:UUID(),call:call,expires:now.addingTimeInterval(120),taskID:taskID)
        pending[proposal.id] = proposal; return proposal
    }
    public func consume(_ proposal: ActionProposal, now: Date = Date()) throws -> ToolCall {
        guard let actual = pending.removeValue(forKey:proposal.id), tasks.contains(actual.taskID),
              actual.taskID == proposal.taskID, actual.call == proposal.call, actual.expires == proposal.expires, now < actual.expires
        else { throw JarvisError.message("Approval expired, changed, or was already used.") }
        return actual.call
    }
}
public enum PathPolicy {
    public static func resolve(_ path: String, roots: [URL], mustExist: Bool = true) throws -> URL {
        let candidate = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        let approved = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard approved.contains(where: { candidate.path == $0 || candidate.path.hasPrefix($0 + "/") }) else { throw JarvisError.message("File is outside approved folders.") }
        if mustExist && !FileManager.default.fileExists(atPath:candidate.path) { throw JarvisError.message("File no longer exists.") }
        return candidate
    }
}
public enum ToolCatalog {
    public static var definitions: [[String:Any]] {
        ActionPolicy.allowed.keys.sorted().map { name in
            let fields = ActionPolicy.allowed[name]!.sorted()
            let descriptions: [String:String] = ["search_documents":"Search selected local folders; returns passages and file paths.","read_document":"Read an approved PDF, Markdown or text file.","open_app":"Open an app explicitly allowed in settings by bundle ID.","web_search":"Search the public web. Do not put private document or email content into a query.","gmail_search":"Search Gmail with Gmail query syntax.","gmail_read":"Read one email by its returned ID.","save_draft":"Save an email draft locally without sending.","send_email":"Propose sending an email to one explicit address. User approval required.","calendar_list":"List primary calendar events between two instants. start and end are each ONE ISO8601 timestamp with a UTC offset, for example 2026-09-11T12:00:00-04:00. Never put a range, a slash, or two timestamps in one field.","calendar_create":"Propose creating an event. start and end are each ONE ISO8601 timestamp with a UTC offset, never a range or slash. timezone is an IANA identifier; attendees are comma-separated emails, or an empty string when there are none.","calendar_update":"Propose replacing the specified primary calendar event fields. Explicit user approval required.","create_reminder":"Propose an Apple Reminder. due is ONE ISO8601 timestamp with a UTC offset, or an empty string when no time was given.","save_memory":"Propose saving a lasting preference only when user asks.","move_file":"Propose moving a file between approved folders; will not overwrite an existing file.","trash_file":"Propose moving an approved file to Trash; never permanently deletes."]
            return ["type":"function","function":["name":name,"description":descriptions[name] ?? name,"parameters":["type":"object","properties":Dictionary(uniqueKeysWithValues:fields.map { ($0,["type":"string"]) }),"required":fields,"additionalProperties":false]]]
        }
    }
}
