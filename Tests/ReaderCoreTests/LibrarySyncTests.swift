import Foundation
import Testing
@testable import ReaderCore

/// The account's library on a fake server, shared by two devices.
final class FakeLibraryServer: @unchecked Sendable {
    var books: [String: RemoteBook] = [:]
    var files: [String: Data] = [:]
    var clock: Int64 = 1

    struct Api: LibraryApi {
        let server: FakeLibraryServer

        func list() async throws -> [RemoteBook] { server.books.values.sorted { $0.addedAt < $1.addedAt } }

        func add(_ doc: DocumentRecord) async throws {
            server.clock += 1
            let had = server.books[doc.id]
            server.books[doc.id] = RemoteBook(documentId: doc.id, title: doc.title, format: doc.format, sizeBytes: doc.sizeBytes,
                                              pageCount: doc.pageCount, hasFile: had?.removedAt == nil && had?.hasFile == true,
                                              addedAt: server.clock, removedAt: nil)
        }

        func remove(_ documentId: String) async throws {
            server.clock += 1
            server.books[documentId]?.removedAt = server.clock
            server.books[documentId]?.hasFile = false
            server.files[documentId] = nil
        }

        func upload(_ documentId: String, file: URL) async throws {
            server.files[documentId] = try Data(contentsOf: file)
            server.books[documentId]?.hasFile = true
        }

        func download(_ documentId: String) async throws -> URL {
            let url = tempDir().appendingPathComponent("download")
            try server.files[documentId]!.write(to: url)
            return url
        }
    }
}

@MainActor
private final class LibraryDevice {
    let documents: DocumentRepository
    let sync: LibrarySync
    let dir = tempDir()

    init(_ server: FakeLibraryServer) throws {
        let db = try ReaderDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        documents = DocumentRepository(db: db, directory: dir.appendingPathComponent("documents"))
        sync = LibrarySync(documents: documents, stateFile: dir.appendingPathComponent("library-sync.json"))
        sync.api = FakeLibraryServer.Api(server: server)
    }

    func add(_ name: String, text: String) throws -> DocumentRecord {
        let url = dir.appendingPathComponent("\(name).pdf")
        makePdf([bookPage(1, [text])], to: url)
        return try documents.importFile(url)
    }

    var ids: Set<String> { Set(((try? documents.library()) ?? []).map(\.id)) }
}

@MainActor
@Suite struct LibrarySyncTests {
    @Test func aBookAddedOnOneDeviceAppearsOnTheOtherWithItsTitle() async throws {
        let server = FakeLibraryServer()
        let mac = try LibraryDevice(server), laptop = try LibraryDevice(server)
        let doc = try mac.add("Meditations", text: "Book one.")
        #expect(await mac.sync.runOnce() == nil)
        #expect(server.books[doc.id]?.hasFile == true)

        #expect(await laptop.sync.runOnce() == nil)
        let synced = try #require(try laptop.documents.get(doc.id))
        #expect(synced.title == "Meditations")
        #expect(FileManager.default.contentsEqual(atPath: synced.localPath, andPath: doc.localPath))
    }

    @Test func removingABookRemovesItEverywhere() async throws {
        let server = FakeLibraryServer()
        let mac = try LibraryDevice(server), laptop = try LibraryDevice(server)
        let doc = try mac.add("Meditations", text: "Book one.")
        await mac.sync.runOnce()
        await laptop.sync.runOnce()
        #expect(laptop.ids == [doc.id])

        try laptop.documents.remove(doc.id)
        laptop.sync.removedLocally(doc.id)
        await laptop.sync.runOnce()
        #expect(server.books[doc.id]?.removedAt != nil)

        await mac.sync.runOnce()
        #expect(mac.ids.isEmpty)
    }

    @Test func aBookAddedOfflineAfterItWasRemovedElsewhereComesBack() async throws {
        let server = FakeLibraryServer()
        let mac = try LibraryDevice(server), laptop = try LibraryDevice(server)
        let doc = try mac.add("Meditations", text: "Book one.")
        await mac.sync.runOnce()
        try mac.documents.remove(doc.id)
        mac.sync.removedLocally(doc.id)
        await mac.sync.runOnce()

        // The laptop never saw the book in the account; adding it is a new add, not a stale copy.
        let again = try laptop.documents.importFile(mac.dir.appendingPathComponent("Meditations.pdf"))
        #expect(again.id == doc.id)
        await laptop.sync.runOnce()
        #expect(laptop.ids == [doc.id])
        #expect(server.books[doc.id]?.removedAt == nil)
        await mac.sync.runOnce()
        #expect(mac.ids == [doc.id])
    }
}
