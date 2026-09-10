import XCTest
import CryptoKit
@testable import JarvisCore

/// Coverage for the tools that actually touch the user's files: the document index
/// behind search_documents, and the move/trash/read operations.
final class DocumentToolTests: XCTestCase {
    private var folder: URL!
    private var root: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = folder.appendingPathComponent("approved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = try Vault(url: folder.appendingPathComponent("vault.enc"), key: SymmetricKey(size: .bits256))
    }
    override func tearDownWithError() throws {
        vault = nil
        try? FileManager.default.removeItem(at: folder)
    }
    private func write(_ name: String, _ body: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: index

    func testSearchFindsPassageAndCitesItsFile() throws {
        let note = try write("lease.md", "The lease agreement renews in November. Rent is fixed.")
        _ = try write("other.txt", "Unrelated grocery list with bananas.")
        try DocumentIndex.refresh(vault, roots: [root])

        let hits = try DocumentIndex.search(vault, query: "lease agreement")
        XCTAssertFalse(hits.isEmpty)
        // Whatever form the index cites, read_document must accept it. If these two
        // disagreed (/var vs /private/var) the assistant would cite files it cannot open.
        let cited = try XCTUnwrap(hits.first?["source"])
        XCTAssertTrue(cited.hasSuffix("approved/lease.md"))
        XCTAssertEqual(try DocumentIndex.contents(of: cited, roots: [root]),
                       "The lease agreement renews in November. Rent is fixed.")
        _ = note
        XCTAssertTrue(hits.first?["passage"].map { $0.contains("renews in November") } ?? false)

        // A term in no document returns nothing rather than every document.
        XCTAssertTrue(try DocumentIndex.search(vault, query: "kryptonite").isEmpty)
    }

    func testUnchangedFilesAreNotReindexed() throws {
        _ = try write("a.md", "alpha content")
        _ = try write("b.txt", "beta content")
        XCTAssertEqual(try DocumentIndex.refresh(vault, roots: [root]).indexed, 2)
        // The whole point of the fingerprint: a repeat search must not re-extract anything.
        XCTAssertEqual(try DocumentIndex.refresh(vault, roots: [root]).indexed, 0)
    }

    func testEditedFileReplacesItsOldPassages() throws {
        let note = try write("memo.md", "the original secret word is aardvark")
        try DocumentIndex.refresh(vault, roots: [root])
        XCTAssertFalse(try DocumentIndex.search(vault, query: "aardvark").isEmpty)

        // Touch size and mtime so the fingerprint changes.
        try "the replacement word is zebra".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: note.path)
        XCTAssertEqual(try DocumentIndex.refresh(vault, roots: [root]).indexed, 1)

        XCTAssertTrue(try DocumentIndex.search(vault, query: "aardvark").isEmpty, "stale passage still searchable")
        XCTAssertFalse(try DocumentIndex.search(vault, query: "zebra").isEmpty)
    }

    func testDeletedFileLeavesTheIndex() throws {
        let note = try write("temp.md", "ephemeral pangolin notes")
        try DocumentIndex.refresh(vault, roots: [root])
        XCTAssertFalse(try DocumentIndex.search(vault, query: "pangolin").isEmpty)

        try FileManager.default.removeItem(at: note)
        XCTAssertEqual(try DocumentIndex.refresh(vault, roots: [root]).dropped, 1)
        XCTAssertTrue(try DocumentIndex.search(vault, query: "pangolin").isEmpty)
    }

    func testFilesOutsideApprovedFoldersAreNeverIndexed() throws {
        let outside = folder.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = try write("diary.md", "confidential wombat confession", in: outside)
        _ = try write("public.md", "ordinary content", in: root)

        try DocumentIndex.refresh(vault, roots: [root])
        XCTAssertTrue(try DocumentIndex.search(vault, query: "wombat").isEmpty)
        XCTAssertFalse(try DocumentIndex.search(vault, query: "ordinary").isEmpty)
    }

    // MARK: chunking

    func testChunksOverlapAndCoverTheWholeDocument() {
        let text = String((0..<5000).map { _ in "x" }) + "NEEDLE"
        let pieces = DocumentIndex.chunk(text, size: 1600, overlap: 200)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.contains { $0.contains("NEEDLE") }, "tail of the document was dropped")
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 1600 })
        XCTAssertTrue(DocumentIndex.chunk("").isEmpty)
    }

    func testChunkingLongDocumentStaysLinear() {
        // The previous implementation walked the string from the start for every chunk,
        // so a 400 KB document took quadratic time. This finishes in well under a second.
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 16_000)  // ~430 KB
        let started = Date()
        let pieces = DocumentIndex.chunk(text, size: 1600, overlap: 200, limit: 1000)
        XCTAssertGreaterThan(pieces.count, 100)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "chunking regressed to quadratic")
    }

    // MARK: reading

    func testReadRefusesEscapesAndUnsupportedTypes() throws {
        _ = try write("notes.md", "readable content")
        XCTAssertEqual(try DocumentIndex.contents(of: root.appendingPathComponent("notes.md").path, roots: [root]),
                       "readable content")
        _ = try write("archive.zip", "binary-ish")
        XCTAssertThrowsError(try DocumentIndex.contents(of: root.appendingPathComponent("archive.zip").path, roots: [root]))
        XCTAssertThrowsError(try DocumentIndex.contents(of: "/etc/passwd", roots: [root]))
        XCTAssertThrowsError(try DocumentIndex.contents(of: root.path, roots: [root]), "a directory is not a document")
    }

    // MARK: move and trash

    func testMoveStaysInsideApprovedFoldersAndNeverOverwrites() throws {
        let source = try write("report.md", "quarterly numbers")
        let destination = root.appendingPathComponent("archive/report.md")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        try DocumentIndex.move(from: source.path, to: destination.path, roots: [root])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "quarterly numbers")

        // Refuses to clobber an existing file.
        let another = try write("report.md", "different content")
        XCTAssertThrowsError(try DocumentIndex.move(from: another.path, to: destination.path, roots: [root]))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "quarterly numbers")

        // Refuses to move outside the approved folders, in either direction.
        let outside = folder.appendingPathComponent("escape.md")
        XCTAssertThrowsError(try DocumentIndex.move(from: another.path, to: outside.path, roots: [root]))
        XCTAssertThrowsError(try DocumentIndex.move(from: "/etc/hosts", to: root.appendingPathComponent("hosts").path, roots: [root]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testMoveAndTrashRefuseTheApprovedRootItself() throws {
        XCTAssertThrowsError(try DocumentIndex.trash(root.path, roots: [root]))
        XCTAssertThrowsError(try DocumentIndex.move(from: root.path,
                                                    to: folder.appendingPathComponent("moved").path, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "approved root was destroyed")
    }

    func testTrashRefusesFilesOutsideApprovedFolders() throws {
        let outside = try write("outside.md", "not yours", in: folder)
        XCTAssertThrowsError(try DocumentIndex.trash(outside.path, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
