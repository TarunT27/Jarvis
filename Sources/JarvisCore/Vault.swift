import Foundation
import Security
import CryptoKit
import CSQLite
import LocalAuthentication

public enum Keychain {
    public static func read(_ account: String, authenticationContext: LAContext? = nil) throws -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Configuration.appID,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var query = q
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw JarvisError.message("Keychain is unavailable (\(status)).") }
        return result as? Data
    }
    public static func write(_ data: Data, account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Configuration.appID, kSecAttrAccount as String: account]
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw JarvisError.message("Could not save credential (\(s)).") }
        } else if status != errSecSuccess { throw JarvisError.message("Could not update credential (\(status)).") }
    }
    public static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Configuration.appID, kSecAttrAccount as String: account] as CFDictionary)
    }
    /// The vault's root key, and the only Keychain item Jarvis owns.
    ///
    /// This must be called from the main application. The broker is an XPC service with
    /// no keychain interaction session, so creating an item there fails with
    /// errSecInteractionNotAllowed; the app reads or creates the key and hands it to the
    /// broker over the code-signature-pinned XPC connection. Every other credential -
    /// Google tokens, the OAuth client, the search key - lives inside the encrypted vault,
    /// which only the broker opens.
    public static func vaultKey(authenticationContext: LAContext? = nil) throws -> SymmetricKey {
        if let data = try read("vault-key", authenticationContext: authenticationContext) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try write(key.withUnsafeBytes { Data($0) }, account: "vault-key")
        return key
    }
}

/// SQLite exists only in RAM. Its complete serialized image is AES-GCM encrypted on disk.
/// No plaintext SQLite pages, WAL, search index, or journal are persisted.
public final class Vault: CredentialStore {
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// save() re-encrypts and rewrites the whole database, so it is deferred: writes mark
    /// the vault dirty and the broker flushes once per request. Anything that must survive
    /// a crash mid-request - the outbox intent written before a send, and credentials -
    /// passes durable: true and is written immediately.
    private var dirty = false
    public init(url: URL, key: SymmetricKey) throws {
        self.url = url; self.key = key
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw JarvisError.message("Cannot open memory database.") }
        if FileManager.default.fileExists(atPath: url.path) {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let data = try AES.GCM.open(box, using: key)
            guard let p = sqlite3_malloc64(UInt64(data.count)) else { throw JarvisError.message("Database allocation failed.") }
            data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: data.count)
            let rc = sqlite3_deserialize(db, "main", p.assumingMemoryBound(to: UInt8.self), Int64(data.count), Int64(data.count), UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE))
            guard rc == SQLITE_OK else { throw JarvisError.message("Cannot read encrypted database.") }
        }
        try execute("PRAGMA temp_store=MEMORY")
        try execute("PRAGMA secure_delete=ON")
        try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, body TEXT NOT NULL, source TEXT NOT NULL, created REAL NOT NULL)")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, body)")
        try prune()
    }
    deinit {
        // Deferred writes must not die with the process. Best effort: if this fails the
        // data is lost either way, and deinit cannot throw.
        if dirty { try? save() }
        sqlite3_close(db)
    }
    private func execute(_ sql: String, _ args: [String] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw JarvisError.message("Database statement failed.") }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i+1), a, -1, transient) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw JarvisError.message("Database update failed.") }
    }
    public func put(kind: String, body: String, source: String = "", id: String = UUID().uuidString, durable: Bool = false) throws {
        try execute("DELETE FROM search WHERE id=?", [id])
        try execute("INSERT OR REPLACE INTO records VALUES (?,?,?,?,?)", [id,kind,body,source,String(Date().timeIntervalSince1970)])
        try execute("INSERT INTO search VALUES (?,?)", [id,body])
        dirty = true; if durable { try save() }
    }
    /// Persist any deferred writes. Call at the end of each request.
    public func flush() throws { if dirty { try save() } }
    public func rows(kind: String? = nil, query: String? = nil, limit: Int = 200) throws -> [[String: String]] {
        var sql = "SELECT r.id,r.kind,r.body,r.source,r.created FROM records r"
        var args: [String] = []; var clauses: [String] = []
        if let query, !query.isEmpty {
            let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
            if terms.isEmpty { return [] }
            sql += " JOIN search s ON s.id=r.id"; clauses.append("search MATCH ?"); args.append(terms)
        }
        if let kind { clauses.append("r.kind=?"); args.append(kind) }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY r.created DESC LIMIT \(max(1, min(limit, 100_000)))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw JarvisError.message("Search failed.") }
        defer { sqlite3_finalize(stmt) }
        for (i,a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i+1), a, -1, transient) }
        var result: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for (i,k) in ["id","kind","body","source","created"].enumerated() {
                if let c = sqlite3_column_text(stmt, Int32(i)) { row[k] = String(cString: c) }
            }
            result.append(row)
        }
        return result
    }
    /// Credentials the broker owns. Stored in the encrypted database rather than the
    /// Keychain so an XPC service can write them without a user-interaction session.
    public func credential(_ name: String) throws -> Data? {
        guard let row = try rows(kind: "credential").first(where: { $0["id"] == "credential:" + name }),
              let body = row["body"] else { return nil }
        return Data(base64Encoded: body)
    }
    public func setCredential(_ data: Data?, for name: String) throws {
        guard let data else { try? delete(id: "credential:" + name); return }
        try put(kind: "credential", body: data.base64EncodedString(), id: "credential:" + name, durable: true)
    }
    public func delete(id: String) throws { try execute("DELETE FROM search WHERE id=?",[id]); try execute("DELETE FROM records WHERE id=?",[id]); try save() }

    /// Removes every row of a kind that came from one source, in two statements rather
    /// than a scan of the whole table per file.
    public func deleteAll(kind: String, source: String) throws {
        try execute("DELETE FROM search WHERE id IN (SELECT id FROM records WHERE kind=? AND source=?)", [kind, source])
        try execute("DELETE FROM records WHERE kind=? AND source=?", [kind, source])
        dirty = true
    }
    public func clear(kind: String? = nil) throws {
        if let kind {
            try execute("DELETE FROM search WHERE id IN (SELECT id FROM records WHERE kind=?)", [kind])
            try execute("DELETE FROM records WHERE kind=?", [kind])
        } else { try execute("DELETE FROM search"); try execute("DELETE FROM records") }
        try save()
    }
    public func prune() throws {
        let cutoff = String(Date().addingTimeInterval(-30*86400).timeIntervalSince1970)
        try execute("DELETE FROM search WHERE id IN (SELECT id FROM records WHERE kind IN ('chat','audit') AND created < CAST(? AS REAL))", [cutoff])
        try execute("DELETE FROM records WHERE kind IN ('chat','audit') AND created < CAST(? AS REAL)", [cutoff]); dirty = true
    }
    private func save() throws {
        var count: Int64 = 0
        guard let ptr = sqlite3_serialize(db, "main", &count, 0) else { throw JarvisError.message("Cannot serialize database.") }
        defer { sqlite3_free(ptr) }
        let plain = Data(bytes: ptr, count: Int(count))
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        dirty = false
    }
}
