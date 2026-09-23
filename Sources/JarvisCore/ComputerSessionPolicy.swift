import Foundation

/// Names and argument limits for the native computer-use surface.
///
/// Tool arguments intentionally remain strings because they travel through the
/// existing model/XPC JSON contract.  The broker validates the exact shape and
/// ranges before a call reaches the native worker.
public enum ComputerToolCatalog {
    public static let observe = "computer_observe"
    public static let click = "computer_click"
    public static let type = "computer_type"
    public static let key = "computer_key"
    public static let scroll = "computer_scroll"
    public static let focus = "computer_focus"

    public static let all: Set<String> = [observe, click, type, key, scroll, focus]
    public static let readOnly: Set<String> = [observe]
    public static let mutating: Set<String> = all.subtracting(readOnly)

    public static let supportedKeys: Set<String> = [
        "cmd+n", "cmd+a", "cmd+c", "return", "tab", "escape",
        "left", "right", "up", "down", "backspace"
    ]
    public static let supportedScrollDirections: Set<String> = ["up", "down", "left", "right"]

    /// Element IDs are indexes in the worker's latest accessibility snapshot.
    /// The bound prevents oversized integers from becoming an alternate input
    /// channel while leaving room for large accessibility trees.
    public static let maxElement = 9_999
    public static let maxTypedTextBytes = 2_000

    public static func isComputerTool(_ name: String) -> Bool { all.contains(name) }
}

/// One supervised app session.  A session is tied to one task and one app;
/// ending the task or reaching either limit invalidates it.
public struct ComputerSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let bundleID: String
    public let appName: String
    public let startedAt: Date
    public let expiresAt: Date
    public internal(set) var actionCount: Int

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        bundleID: String,
        appName: String = "",
        startedAt: Date,
        expiresAt: Date,
        actionCount: Int = 0
    ) {
        self.id = id
        self.taskID = taskID
        self.bundleID = bundleID
        self.appName = appName
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.actionCount = actionCount
    }

    public var remainingActions: Int {
        max(0, ComputerSessionPolicy.maximumActions - actionCount)
    }

    public func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }
}

/// Broker-side state machine for the single native computer session.
///
/// The policy does not ask for TCC permissions or launch applications.  Those
/// operations belong to the broker/native worker boundary.  It only makes
/// session ownership, expiry, and action budgets explicit and testable without
/// live macOS permissions.
public final class ComputerSessionPolicy {
    public static let maximumDuration: TimeInterval = 5 * 60
    public static let maximumActions = 30

    private var current: ComputerSession?

    public init() {}

    /// The current unexpired session. Expired state is retained until explicit cleanup.
    public var session: ComputerSession? { currentSession() }

    public func currentSession(at now: Date = Date()) -> ComputerSession? {
        guard let current else { return nil }
        guard !current.isExpired(at: now) else {
            return nil
        }
        return current
    }

    /// Returns and clears an expired session so the broker can stop the native
    /// worker and revoke pending approvals for its task.
    @discardableResult
    public func expireIfNeeded(at now: Date = Date()) -> ComputerSession? {
        guard let current, current.isExpired(at: now) else { return nil }
        self.current = nil
        return current
    }

    /// Starts one session globally.  A second task cannot borrow the first
    /// task's native controller or approvals.
    @discardableResult
    public func start(
        taskID: UUID,
        bundleID: String,
        appName: String = "",
        at now: Date = Date()
    ) throws -> ComputerSession {
        _ = expireIfNeeded(at: now)
        guard current == nil else {
            throw JarvisError.message("A computer session is already active for another task.")
        }
        try Self.validateBundleID(bundleID)
        let session = ComputerSession(
            taskID: taskID,
            bundleID: bundleID,
            appName: appName,
            startedAt: now,
            expiresAt: now.addingTimeInterval(Self.maximumDuration)
        )
        current = session
        return session
    }

    /// Alias used by callers that describe task lifecycle as begin/end.
    @discardableResult
    public func begin(
        taskID: UUID,
        bundleID: String,
        appName: String = "",
        at now: Date = Date()
    ) throws -> ComputerSession {
        try start(taskID: taskID, bundleID: bundleID, appName: appName, at: now)
    }

    /// Stops only the requested task's session.  A stale task completion cannot
    /// stop a newer session owned by another task.
    @discardableResult
    public func stop(taskID: UUID? = nil) -> ComputerSession? {
        guard let current, taskID == nil || current.taskID == taskID else { return nil }
        self.current = nil
        return current
    }

    public func end(taskID: UUID? = nil) { _ = stop(taskID: taskID) }
    public func stopAll() { current = nil }

    /// Validates that a task still owns the exact session that produced a
    /// pending approval.  Approvals never survive stop, expiry, or task changes.
    @discardableResult
    public func validateApproval(
        taskID: UUID,
        sessionID: UUID,
        at now: Date = Date()
    ) throws -> ComputerSession {
        guard let session = currentSession(at: now), session.taskID == taskID else {
            throw JarvisError.message("The computer session is no longer active for this task.")
        }
        guard session.id == sessionID else {
            throw JarvisError.message("This computer approval belongs to an expired or different session.")
        }
        guard session.actionCount < Self.maximumActions else {
            throw JarvisError.message("The computer session reached its 30-action limit.")
        }
        return session
    }

    /// Reserves one native action immediately before execution.  Counting
    /// attempts, including one that later fails in the worker, prevents retries
    /// from bypassing the 30-action bound.
    @discardableResult
    public func reserveAction(
        taskID: UUID,
        sessionID: UUID,
        at now: Date = Date()
    ) throws -> ComputerSession {
        let session = try validateApproval(taskID: taskID, sessionID: sessionID, at: now)
        var updated = session
        updated.actionCount += 1
        current = updated
        return updated
    }

    public func isActive(taskID: UUID, sessionID: UUID? = nil, at now: Date = Date()) -> Bool {
        guard let session = currentSession(at: now), session.taskID == taskID else { return false }
        return sessionID == nil || session.id == sessionID
    }

    /// Enforces the exact JSON argument schema for a computer tool.
    public static func validate(_ call: ToolCall) throws {
        guard ComputerToolCatalog.all.contains(call.name) else {
            throw JarvisError.message("Unsupported computer tool.")
        }

        let required: Set<String>
        switch call.name {
        case ComputerToolCatalog.observe, ComputerToolCatalog.focus: required = []
        case ComputerToolCatalog.click: required = ["snapshot", "element"]
        case ComputerToolCatalog.type: required = ["snapshot", "element", "text"]
        case ComputerToolCatalog.key: required = ["snapshot", "key"]
        case ComputerToolCatalog.scroll: required = ["snapshot", "direction", "amount"]
        default: required = []
        }
        guard Set(call.arguments.keys) == required else {
            throw JarvisError.message("Invalid arguments for \(call.name).")
        }

        if required.contains("snapshot") {
            let raw = call.arguments["snapshot"] ?? ""
            guard UUID(uuidString: raw) != nil else {
                throw JarvisError.message("Computer snapshot must be a UUID from the latest observation.")
            }
        }

        if required.contains("element") {
            let raw = call.arguments["element"] ?? ""
            guard raw.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil,
                  let element = Int(raw), (0...ComputerToolCatalog.maxElement).contains(element) else {
                throw JarvisError.message("Computer element must be a bounded numeric snapshot element.")
            }
        }

        if call.name == ComputerToolCatalog.type {
            let text = call.arguments["text"] ?? ""
            guard text.utf8.count <= ComputerToolCatalog.maxTypedTextBytes, !text.contains("\0") else {
                throw JarvisError.message("Computer text is limited to 2,000 bytes and cannot contain null characters.")
            }
        }

        if call.name == ComputerToolCatalog.key {
            guard let key = call.arguments["key"], ComputerToolCatalog.supportedKeys.contains(key) else {
                throw JarvisError.message("Unsupported computer key.")
            }
        }

        if call.name == ComputerToolCatalog.scroll {
            guard let direction = call.arguments["direction"], ComputerToolCatalog.supportedScrollDirections.contains(direction),
                  let rawAmount = call.arguments["amount"],
                  rawAmount.range(of: "^[1-5]$", options: .regularExpression) != nil,
                  let amount = Int(rawAmount), (1...5).contains(amount) else {
                throw JarvisError.message("Computer scroll direction or amount is invalid.")
            }
        }
    }

    public func validate(_ call: ToolCall) throws { try Self.validate(call) }

    private static func validateBundleID(_ value: String) throws {
        guard value.utf8.count <= 256, !value.isEmpty, !value.contains("\0"),
              value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
            throw JarvisError.message("Choose one installed application by bundle ID.")
        }
    }
}
