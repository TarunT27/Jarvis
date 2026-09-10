import Foundation
import CryptoKit
#if canImport(PDFKit)
import PDFKit
#endif

/// Full-text index over the approved folders, and the file operations that touch them.
///
/// Extracted from the broker so the parts that read, move and trash real files can be
/// tested directly; the broker keeps the permission decisions and the XPC surface.
public enum DocumentIndex {
    public static let supported: Set<String> = ["pdf", "txt", "md", "markdown"]

    /// Splits text into overlapping windows in one pass.
    ///
    /// Calling `text.index(startIndex, offsetBy:)` per chunk walks the string from the
    /// beginning every time, which is quadratic in document length. Advancing from the
    /// previous index keeps it linear.
    public static func chunk(_ text: String, size: Int = 1600, overlap: Int = 200, limit: Int = 400) -> [String] {
        guard !text.isEmpty, size > overlap else { return [] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex, result.count < limit {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(start, offsetBy: size - overlap, limitedBy: text.endIndex) ?? text.endIndex
        }
        return result
    }

    public static func key(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads an approved document. Refuses anything outside the approved folders,
    /// anything that is not a regular file, and anything oversized.
    public static func contents(of path: String, roots: [URL], maxBytes: Int = 10_000_000) throws -> String {
        let safe = try PathPolicy.resolve(path, roots: roots)
        let values = try safe.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) < maxBytes else {
            throw JarvisError.message("Only regular documents under 10 MB are supported.")
        }
        let ext = safe.pathExtension.lowercased()
        if ext == "pdf" {
            #if canImport(PDFKit)
            guard let pdf = PDFDocument(url: safe) else { throw JarvisError.message("PDF could not be opened.") }
            return (0..<min(pdf.pageCount, 150)).compactMap { index in
                pdf.page(at: index)?.string.map { "[Page \(index + 1)]\n" + $0 }
            }.joined(separator: "\n")
            #else
            throw JarvisError.message("PDF support is unavailable.")
            #endif
        }
        guard ["txt", "md", "markdown"].contains(ext) else {
            throw JarvisError.message("Only PDF, Markdown, and text are supported.")
        }
        return try String(contentsOf: safe, encoding: .utf8)
    }

    /// Brings the index in line with the approved folders.
    ///
    /// Only files whose size or modification date changed are re-extracted, so a repeat
    /// search costs a directory walk instead of re-parsing every PDF. Returns the number
    /// of files reindexed and dropped, which the tests assert on.
    @discardableResult
    public static func refresh(_ vault: Vault, roots: [URL], fileLimit: Int = 5000) throws -> (indexed: Int, dropped: Int) {
        var fingerprints: [String: String] = [:]
        for row in try vault.rows(kind: "docmeta", limit: 20_000) {
            if let source = row["source"], let body = row["body"] { fingerprints[source] = body }
        }
        var present = Set<String>(), inspected = 0, indexed = 0
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                inspected += 1
                if inspected > fileLimit { break }
                guard supported.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                // Store the same canonical form PathPolicy produces, so a path cited in a
                // search result is always one read_document will accept. The enumerator and
                // PathPolicy can otherwise disagree (/var vs /private/var).
                guard let safe = try? PathPolicy.resolve(url.path, roots: roots) else { continue }
                let path = safe.path
                present.insert(path)
                let stamp = "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                if fingerprints[path] == stamp { continue }
                guard let text = try? contents(of: path, roots: roots) else { continue }
                try drop(vault, path: path)
                for (index, piece) in chunk(String(text.prefix(400_000))).enumerated() {
                    try vault.put(kind: "document", body: piece, source: path, id: "doc:\(key(path)):\(index)")
                }
                try vault.put(kind: "docmeta", body: stamp, source: path, id: "docmeta:\(key(path))")
                indexed += 1
            }
        }
        // Forget files deleted or no longer inside an approved folder.
        let gone = fingerprints.keys.filter { !present.contains($0) }
        for path in gone { try drop(vault, path: path) }
        return (indexed, gone.count)
    }

    public static func drop(_ vault: Vault, path: String) throws {
        try vault.deleteAll(kind: "document", source: path)
        try vault.deleteAll(kind: "docmeta", source: path)
    }

    public static func search(_ vault: Vault, query: String, limit: Int = 8) throws -> [[String: String]] {
        try vault.rows(kind: "document", query: query, limit: limit)
            .map { ["source": $0["source"] ?? "", "passage": $0["body"] ?? ""] }
    }

    /// Moves a file between approved folders. Will not overwrite, and will not move a root.
    public static func move(from source: String, to destination: String, roots: [URL]) throws {
        let from = try PathPolicy.resolve(source, roots: roots)
        let to = try PathPolicy.resolve(destination, roots: roots, mustExist: false)
        let approved = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !approved.contains(from.path), !FileManager.default.fileExists(atPath: to.path) else {
            throw JarvisError.message("Cannot move an approved root or overwrite an existing file.")
        }
        try FileManager.default.moveItem(at: from, to: to)
    }

    /// Moves an approved file to Trash. Never deletes permanently, never trashes a root.
    public static func trash(_ path: String, roots: [URL]) throws {
        let target = try PathPolicy.resolve(path, roots: roots)
        let approved = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        guard !approved.contains(target.path) else { throw JarvisError.message("Cannot trash an approved root folder.") }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }
}
