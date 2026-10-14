import CryptoKit
import Foundation
import Testing
@testable import ReaderCore

@Suite struct LibraryTests {
    @Test func importCopiesTheFileAndUsesItsSha256AsTheId() throws {
        let dir = tempDir()
        let db = try ReaderDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        let repo = DocumentRepository(db: db, directory: dir.appendingPathComponent("documents"))
        let original = dir.appendingPathComponent("Meditations.pdf")
        makePdf([bookPage(1, ["One."]), bookPage(2, ["Two."])], to: original)
        let expected = SHA256.hash(data: try Data(contentsOf: original)).map { String(format: "%02x", $0) }.joined()

        let doc = try repo.importFile(original)
        #expect(doc.id == expected)
        #expect(doc.format == "PDF")
        #expect(doc.pageCount == 2)
        #expect(doc.title == "Meditations")
        #expect(FileManager.default.contentsEqual(atPath: doc.localPath, andPath: original.path))

        // The same bytes from somewhere else are the same book.
        let copy = dir.appendingPathComponent("renamed copy.pdf")
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.removeItem(at: original)
        #expect(try repo.importFile(copy).id == expected)
        #expect(try repo.library().count == 1)
        #expect(try repo.library().first?.progressLabel == "Not started · 2 pages")
        #expect(FileManager.default.fileExists(atPath: doc.localPath), "readable after the original is gone")
    }

    @Test func epubsAreImportedWithTheirTitleAndChapterCount() throws {
        let dir = tempDir()
        let db = try ReaderDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        let repo = DocumentRepository(db: db, directory: dir.appendingPathComponent("documents"))
        let url = dir.appendingPathComponent("book.epub")
        try writeZip(EpubTests().book.map { ($0.0, Data($0.1.utf8)) }, to: url, deflate: true)
        let doc = try repo.importFile(url)
        #expect(doc.format == "EPUB")
        #expect(doc.title == "The Meditations")
        #expect(doc.pageCount == 2)

        let repoPositions = ReadingPositionRepository(store: db, clock: HybridClock(), deviceId: "mac")
        try repoPositions.saveLocal(ReadingPosition(documentId: doc.id, pageIndex: 1, pageOffset: 0.5, pageCount: 2,
                                                    stamp: Stamp(hlc: 0, deviceId: "")))
        #expect(try repo.library().first?.progressLabel == "Chapter 2 of 2 · 75%")
    }

    @Test func otherFilesAreRejected() throws {
        let dir = tempDir()
        let db = try ReaderDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        let repo = DocumentRepository(db: db, directory: dir.appendingPathComponent("documents"))
        let url = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        #expect(throws: UnsupportedFormatError.self) { try repo.importFile(url) }
        #expect(try repo.library().isEmpty)
    }
}
