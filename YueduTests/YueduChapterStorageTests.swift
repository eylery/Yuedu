import XCTest
@testable import Yuedu

@MainActor
final class YueduChapterStorageTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("library.json") }
    private var bodies: URL { directory.appendingPathComponent("chapter-content") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample() -> Book {
        Book(title: "迁移测试", author: "作者", summary: "", category: "",
             coverColor: "517A65", coverSymbol: "book",
             chapters: [BookChapter(title: "第一章", content: String(repeating: "旧正文与中文标点。", count: 20_000)),
                        BookChapter(title: "第二章", content: "独立的第二章")], sourceName: "本地")
    }

    func testLegacyMigrationKeepsExactRecoveryCopyAndPortableBackup() throws {
        let book = sample()
        let bookmark = Bookmark(bookID: book.id, chapterIndex: 1, scrollFraction: 0.4, title: "第二章")
        let original = LibraryStore.Snapshot(books: [book], bookmarks: [bookmark], readingSeconds: 120,
                                             readingDates: ["2026-10-22"])
        let legacy = try JSONEncoder().encode(original)
        try legacy.write(to: file)
        let store = LibraryStore(directory: directory)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.books.first?.chapters[0].content, book.chapters[0].content)
        XCTAssertEqual(store.bookmarks.first?.id, bookmark.id)
        XCTAssertEqual(store.readingSeconds, 120)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library-before-body-split.json")), legacy)
        let metadata = try Data(contentsOf: file)
        XCTAssertLessThan(metadata.count, 4_000)
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("旧正文"))
        let backup = try YueduLibraryBackup.decode(JSONEncoder().encode(YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])))
        XCTAssertEqual(backup.library.books[0].chapters[0].content, book.chapters[0].content)
        XCTAssertEqual(LibraryStore(directory: directory).books[0].chapters[1].content, "独立的第二章")
    }

    func testProgressWritesReuseBodyFilesAndMetadataRemainsSmall() throws {
        let store = LibraryStore(directory: directory)
        let book = store.add(sample())
        let urls = try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: [.contentModificationDateKey])
        let dates = try urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        for index in 0..<20 {
            XCTAssertTrue(store.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: Double(index) / 20))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil)), Set(urls))
        XCTAssertEqual(try urls.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }, dates)
        XCTAssertLessThan(try Data(contentsOf: file).count, 4_000)
        XCTAssertTrue(store.books[0].chapters[0].hasCachedContent)
        XCTAssertEqual(store.books[0].chapters[0].cachedByteCount, book.chapters[0].content.utf8.count)
    }

    func testInterruptedMigrationLeavesLegacyReadableAndCanRetry() throws {
        let legacy = try JSONEncoder().encode(LibraryStore.Snapshot(books: [sample()], bookmarks: [], readingSeconds: 0, readingDates: []))
        try legacy.write(to: file)
        try Data("block chapter directory".utf8).write(to: bodies)
        let failed = LibraryStore(directory: directory)
        XCTAssertNotNil(failed.persistenceError)
        XCTAssertEqual(failed.books.first?.chapters.first?.content, sample().chapters[0].content)
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        try FileManager.default.removeItem(at: bodies)
        XCTAssertTrue(failed.updateProgress(bookID: failed.books[0].id, chapterIndex: 1, scrollFraction: 0.4))
        XCTAssertNil(failed.persistenceError)
        let recovered = LibraryStore(directory: directory)
        XCTAssertNil(recovered.persistenceError)
        XCTAssertEqual(recovered.books[0].chapters[0].content, sample().chapters[0].content)
    }

    func testFailedMetadataCommitDoesNotRetireExistingBodies() throws {
        let store = LibraryStore(directory: directory)
        let book = store.add(sample())
        let original = try Data(contentsOf: file)
        let files = try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.remove(id: book.id))
        XCTAssertEqual(store.books[0].chapters[0].content, book.chapters[0].content)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil)), Set(files))
        try FileManager.default.removeItem(at: file)
        try original.write(to: file)
        XCTAssertTrue(store.updateProgress(bookID: book.id, chapterIndex: 1, scrollFraction: 0.2))
    }

    func testMissingBodyCannotProduceSilentlyIncompleteBackup() throws {
        let store = LibraryStore(directory: directory)
        store.add(sample())
        let body = store.books[0].chapters[0].body
        let reference = try XCTUnwrap(body.reference)
        let bodyFile = bodies.appendingPathComponent(reference.file.uuidString)
        try Data(repeating: 65, count: reference.bytes).write(to: bodyFile)
        XCTAssertThrowsError(try body.read(), "Same-length corruption must fail the content digest check")
        try FileManager.default.removeItem(at: bodyFile)
        XCTAssertThrowsError(try body.read())
        XCTAssertThrowsError(try JSONEncoder().encode(YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])))
        // Listing a large shelf uses recorded metadata, not body I/O.
        XCTAssertTrue(store.books[0].chapters[0].hasCachedContent)
        XCTAssertGreaterThan(store.books[0].cacheSummary.bytes, 0)
    }

    func testCacheCleanupReclaimsBodyFilesAndKeepsLocalBooks() async throws {
        let store = LibraryStore(directory: directory)
        let local = store.add(sample())
        var online = sample()
        online.title = "在线缓存"
        online.sourceID = UUID()
        online.bookURL = "https://fixture.invalid/book"
        online.chapters.append(BookChapter(title: "空白缓存", content: "   \n"))
        store.add(online)
        let summary = try store.clearCachedChapters(bookIDs: [local.id, online.id], cleanup: .all)
        XCTAssertEqual(summary.chapters, 3)
        for _ in 0..<100 {
            if try FileManager.default.contentsOfDirectory(atPath: bodies.path).count == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bodies.path).count, 2)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.book(id: online.id)?.cacheSummary.bytes, 0)
        XCTAssertEqual(restored.book(id: local.id)?.chapters[1].content, "独立的第二章")
    }

    func testStartupRemovesOnlyUnreferencedBodyFiles() throws {
        let store = LibraryStore(directory: directory)
        store.add(sample())
        let orphan = bodies.appendingPathComponent(UUID().uuidString)
        let unrelated = bodies.appendingPathComponent("keep.txt")
        try Data("abandoned write".utf8).write(to: orphan)
        try Data("not a chapter".utf8).write(to: unrelated)
        let recovered = LibraryStore(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(recovered.books[0].chapters[1].content, "独立的第二章")
    }
}
