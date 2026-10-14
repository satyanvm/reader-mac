import CryptoKit
import Foundation
import PDFKit

public struct DocumentRecord: Hashable, Sendable {
    public var id: String
    public var title: String
    public var localPath: String
    public var sizeBytes: Int64
    public var pageCount: Int
    public var lastOpenedAt: Int64
    /// Last mode used for this document on this device: "PAGES" or "TEXT". Not synced.
    public var readingMode: String
    /// "PDF" or "EPUB".
    public var format: String
}

public struct LibraryRow: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var pageCount: Int
    public var lastOpenedAt: Int64
    public var pageIndex: Int?
    public var pageOffset: Float?
    public var format: String

    /// "Page 187 of 500 · 37%", or "Not started · 500 pages".
    public var progressLabel: String {
        let epub = format == "EPUB"
        guard let page = pageIndex else { return "Not started · \(pageCount) \(epub ? "chapters" : "pages")" }
        let read = (Float(page) + (pageOffset ?? 0)) / Float(max(1, pageCount))
        return "\(epub ? "Chapter" : "Page") \(page + 1) of \(pageCount) · \(Int(read * 100))%"
    }
}

public struct UnsupportedFormatError: Error, LocalizedError {
    public var errorDescription: String? { "Only PDF and EPUB files are supported" }
}

/// Imports books into app storage and keeps the library list.
///
/// Each file is copied into the app's own storage and named by the SHA-256 of its bytes. The hash
/// is the document id everywhere, including sync: the same file opened on another device (Mac or
/// Android) gets the same id. The copy keeps the book readable offline, after reboots, and after
/// the original is moved or deleted.
public final class DocumentRepository: @unchecked Sendable {
    private let db: ReaderDatabase
    private let dir: URL
    private let now: () -> Int64

    public init(db: ReaderDatabase, directory: URL, now: @escaping () -> Int64 = HybridClock.systemMillis) {
        self.db = db
        dir = directory
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func library() throws -> [LibraryRow] {
        try db.sql.query("""
            SELECT d.id, d.title, d.pageCount, d.lastOpenedAt, p.pageIndex, p.pageOffset, d.format
            FROM documents d LEFT JOIN reading_positions p ON p.documentId = d.id
            ORDER BY d.lastOpenedAt DESC
            """).map { r in
            LibraryRow(
                id: r["id"]?.string ?? "",
                title: r["title"]?.string ?? "",
                pageCount: r["pageCount"]?.int ?? 0,
                lastOpenedAt: r["lastOpenedAt"]?.int64 ?? 0,
                pageIndex: r["pageIndex"]?.int,
                pageOffset: r["pageOffset"]?.double.map(Float.init),
                format: r["format"]?.string ?? "PDF"
            )
        }
    }

    public func all() throws -> [DocumentRecord] {
        try db.sql.query("SELECT * FROM documents").map(Self.record)
    }

    public func get(_ id: String) throws -> DocumentRecord? {
        try db.sql.query("SELECT * FROM documents WHERE id = ?", [.text(id)]).first.map(Self.record)
    }

    public func touch(_ id: String) throws {
        try db.sql.execute("UPDATE documents SET lastOpenedAt = ? WHERE id = ?", [.int(now()), .text(id)])
        ReaderDatabase.postChange()
    }

    public func setReadingMode(_ id: String, _ mode: ReadingMode) throws {
        try db.sql.execute("UPDATE documents SET readingMode = ? WHERE id = ?", [.text(mode.rawValue), .text(id)])
    }

    public func remove(_ id: String) throws {
        if let doc = try get(id) { try? FileManager.default.removeItem(atPath: doc.localPath) }
        try db.sql.execute("DELETE FROM documents WHERE id = ?", [.text(id)])
        ReaderDatabase.postChange()
    }

    /// Copies `source` into app storage (hashing as it goes) and adds it to the library. Importing
    /// the same bytes again returns the existing document. `title` (a book synced from another
    /// device) is used instead of the file's own title for a new document.
    public func importFile(_ source: URL, title: String? = nil) throws -> DocumentRecord {
        let tmp = dir.appendingPathComponent("import-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        guard let input = InputStream(url: source) else { throw ReaderError(message: "Can't open \(source.lastPathComponent)") }
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        var hasher = SHA256()
        input.open()
        defer { input.close() }
        let bufSize = 1 << 16
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = input.read(&buf, maxLength: bufSize)
            if n < 0 { throw input.streamError ?? ReaderError(message: "Read failed") }
            if n == 0 { break }
            hasher.update(data: buf[0..<n])
            try out.write(contentsOf: buf[0..<n])
        }
        try out.synchronize()
        try out.close()
        let id = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let format: String
        if Self.isPdf(tmp) { format = "PDF" } else if EpubBook.isEpub(tmp) { format = "EPUB" } else { throw UnsupportedFormatError() }
        let target = dir.appendingPathComponent("\(id).\(format.lowercased())")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: tmp, to: target)
        }

        var record: DocumentRecord
        if let existing = try get(id) {
            record = existing
            record.lastOpenedAt = now()
        } else {
            let (pages, bookTitle): (Int, String?)
            if format == "PDF" {
                guard let pdf = PDFDocument(url: target) else { throw ReaderError(message: "Couldn't open this PDF") }
                let meta = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pages = pdf.pageCount
                bookTitle = meta?.isEmpty == false ? meta : nil
            } else {
                let book = try EpubBook.open(target)
                (pages, bookTitle) = (book.pageCount, book.title)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
            record = DocumentRecord(
                id: id,
                title: title ?? bookTitle ?? source.deletingPathExtension().lastPathComponent,
                localPath: target.path,
                sizeBytes: size,
                pageCount: pages,
                lastOpenedAt: now(),
                readingMode: ReadingMode.pages.rawValue,
                format: format
            )
        }
        try put(record)
        return record
    }

    private func put(_ d: DocumentRecord) throws {
        try db.sql.execute(
            """
            INSERT OR REPLACE INTO documents (id, title, localPath, sizeBytes, pageCount, lastOpenedAt, readingMode, format)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(d.id), .text(d.title), .text(d.localPath), .int(d.sizeBytes), .int(Int64(d.pageCount)),
             .int(d.lastOpenedAt), .text(d.readingMode), .text(d.format)]
        )
        ReaderDatabase.postChange()
    }

    private static func isPdf(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 1024)) ?? Data()
        return String(decoding: head, as: Unicode.ASCII.self).contains("%PDF-") ||
            String(data: head, encoding: .isoLatin1)?.contains("%PDF-") == true
    }

    static func record(_ r: SQLiteDatabase.Row) -> DocumentRecord {
        DocumentRecord(
            id: r["id"]?.string ?? "",
            title: r["title"]?.string ?? "",
            localPath: r["localPath"]?.string ?? "",
            sizeBytes: r["sizeBytes"]?.int64 ?? 0,
            pageCount: r["pageCount"]?.int ?? 0,
            lastOpenedAt: r["lastOpenedAt"]?.int64 ?? 0,
            readingMode: r["readingMode"]?.string ?? "PAGES",
            format: r["format"]?.string ?? "PDF"
        )
    }
}
