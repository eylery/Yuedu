import XCTest
@testable import Yuedu

@MainActor
final class YueduLibraryToolsTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LibraryStore(directory: directory, seed: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func book() -> Book {
        Book(title: "测试故事", author: "作者", summary: "简介", category: "测试",
             coverColor: "456C53", coverSymbol: "book",
             chapters: [
                BookChapter(title: "第一章 春日", content: "已缓存的正文", url: "https://example.com/1"),
                BookChapter(title: "第二章 秋日", content: "", url: "https://example.com/2")
             ],
             sourceName: "原书源", sourceID: UUID(), bookURL: "https://example.com/book")
    }

    func testCatalogInsertionMovesProgressAndBookmarkButKeepsCacheIdentity() throws {
        let original = store.add(book())
        store.updateProgress(bookID: original.id, chapterIndex: 1, scrollFraction: 0.37)
        store.addBookmark(bookID: original.id, chapterIndex: 0, scrollFraction: 0.2, title: "春日")
        var fetched = original
        fetched.chapters = [
            BookChapter(title: "序言", content: "", url: "https://example.com/0"),
            BookChapter(title: "第一章 春日", content: "", url: "https://example.com/1"),
            BookChapter(title: "第二章 秋日", content: "", url: "https://example.com/2")
        ]
        XCTAssertEqual(try store.refreshCatalog(bookID: original.id, fetched: fetched), 1)
        let restored = LibraryStore(directory: directory, seed: false)
        XCTAssertEqual(restored.books[0].progress.chapterIndex, 2)
        XCTAssertEqual(restored.books[0].progress.scrollFraction, 0.37)
        XCTAssertEqual(restored.bookmarks[0].chapterIndex, 1)
        XCTAssertEqual(restored.books[0].chapters[1].content, "已缓存的正文")
        XCTAssertEqual(restored.books[0].chapters[1].id, original.chapters[0].id)
    }

    func testUnmatchedReadingChapterLeavesDiskUnchanged() throws {
        let original = store.add(book())
        store.updateProgress(bookID: original.id, chapterIndex: 1, scrollFraction: 0.4)
        let file = directory.appendingPathComponent("library.json")
        let before = try Data(contentsOf: file)
        var fetched = original
        fetched.chapters = [BookChapter(title: "另一本书", content: "", url: "https://example.com/other")]
        XCTAssertThrowsError(try store.refreshCatalog(bookID: original.id, fetched: fetched))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testUnmatchedBookmarkAlsoProtectsOriginalCatalog() throws {
        let original = store.add(book())
        store.addBookmark(bookID: original.id, chapterIndex: 1, scrollFraction: 0.1, title: "秋日")
        var fetched = original
        fetched.chapters.removeLast()
        XCTAssertThrowsError(try store.refreshCatalog(bookID: original.id, fetched: fetched))
        XCTAssertEqual(store.books[0].chapters.count, 2)
        XCTAssertEqual(store.bookmarks[0].chapterIndex, 1)
    }

    func testMatchingDoesNotGuessWithRepeatedTitlesAcrossSources() {
        let original = BookChapter(title: " 正 文 ", content: "")
        XCTAssertNil(YueduCatalog.matchingIndex(original, in: [
            BookChapter(title: "正文", content: ""), BookChapter(title: "正文", content: "")
        ], sameSource: false))
        XCTAssertEqual(YueduCatalog.matchingIndex(original, in: [
            BookChapter(title: "前言", content: ""), BookChapter(title: "正文", content: "")
        ], sameSource: false), 1)
    }

    func testDownloadsSkipCachedChaptersAndSurviveStoreReload() async throws {
        let original = store.add(book())
        var requested: [String] = []
        let manager = YueduDownloadManager(library: store, observeBackground: false) { chapter, _ in
            requested.append(chapter.title)
            return "新下载正文"
        }
        manager.start(bookID: original.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(requested, ["第二章 秋日"])
        XCTAssertEqual(LibraryStore(directory: directory, seed: false).books[0].cachedChapterCount, 2)
        XCTAssertEqual(manager.status(for: original.id)?.message, "缓存完成")
        manager.start(bookID: original.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(requested.count, 1)
    }

    func testDownloadFailureCanBeRetriedWithoutRedownloadingSuccess() async {
        let original = store.add(book())
        var fail = true
        let manager = YueduDownloadManager(library: store, observeBackground: false) { _, _ in
            if fail { throw SourceError.network("测试断网") }
            return "恢复后正文"
        }
        manager.start(bookID: original.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.status(for: original.id)?.failures.count, 1)
        XCTAssertEqual(store.books[0].cachedChapterCount, 1)
        fail = false
        manager.start(bookID: original.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(store.books[0].cachedChapterCount, 2)
        XCTAssertEqual(manager.status(for: original.id)?.failures.count, 0)
    }

    func testPauseCancelsInFlightChapterAndKeepsPreviousCache() async {
        let original = store.add(book())
        let started = expectation(description: "download started")
        let manager = YueduDownloadManager(library: store, observeBackground: false) { _, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "不得写入"
        }
        manager.start(bookID: original.id)
        await fulfillment(of: [started], timeout: 2)
        manager.pause(bookID: original.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(store.books[0].cachedChapterCount, 1)
        XCTAssertFalse(manager.status(for: original.id)!.isRunning)
    }

    func testDownloadQueueProcessesBooksSeriallyAndHonorsRange() async {
        let first = store.add(book())
        var other = book()
        other.title = "另一本"
        let second = store.add(other)
        var order: [UUID] = []
        let manager = YueduDownloadManager(library: store, observeBackground: false) { _, book in
            order.append(book.id)
            return "正文"
        }
        manager.start(bookID: first.id, startIndex: 0, limit: 1)
        manager.start(bookID: second.id)
        await manager.waitUntilIdle()
        XCTAssertEqual(order, [second.id])
        XCTAssertEqual(store.book(id: first.id)?.cachedChapterCount, 1)
        XCTAssertEqual(store.book(id: second.id)?.cachedChapterCount, 2)
    }

    func testBackupRoundTripRemapsSourceAndIsIdempotent() throws {
        let original = store.add(book())
        store.updateProgress(bookID: original.id, chapterIndex: 1, scrollFraction: 0.3)
        store.addBookmark(bookID: original.id, chapterIndex: 0, scrollFraction: 0.25, title: "春日")
        store.recordReading(seconds: 120)
        let backup = YueduLibraryBackup(library: store.snapshot, sourceURLs: [
            original.sourceID!.uuidString: "https://example.com"
        ])
        let decoded = try YueduLibraryBackup.decode(JSONEncoder().encode(backup))
        let destination = LibraryStore(directory: directory.appendingPathComponent("restore"), seed: false)
        var source = BookSource.example
        source.bookSourceUrl = "https://example.com"
        let counts = try decoded.merge(into: destination, sources: [source])
        XCTAssertEqual(counts.books, 1)
        XCTAssertEqual(counts.bookmarks, 1)
        XCTAssertEqual(destination.books[0].sourceID, source.id)
        XCTAssertEqual(destination.books[0].progress.scrollFraction, 0.3)
        destination.updateProgress(bookID: destination.books[0].id, chapterIndex: 0, scrollFraction: 0.9)
        let second = try decoded.merge(into: destination, sources: [source])
        XCTAssertEqual(second.books, 0)
        XCTAssertEqual(second.bookmarks, 0)
        XCTAssertEqual(destination.books[0].progress.scrollFraction, 0.9)
        XCTAssertEqual(destination.readingSeconds, 120)
    }

    func testBackupRejectsInvalidReferencesAndUnsupportedVersion() throws {
        let original = store.add(book())
        var snapshot = store.snapshot
        snapshot.bookmarks = [Bookmark(bookID: original.id, chapterIndex: 999, scrollFraction: 0.2, title: "坏书签")]
        var backup = YueduLibraryBackup(library: snapshot, sourceURLs: [:])
        XCTAssertThrowsError(try YueduLibraryBackup.decode(JSONEncoder().encode(backup)))
        backup.library = store.snapshot
        backup.version = 999
        XCTAssertThrowsError(try YueduLibraryBackup.decode(JSONEncoder().encode(backup)))
        XCTAssertThrowsError(try YueduLibraryBackup.decode(Data("{}".utf8)))
    }

    func testRestoreRemapsBookmarksToExistingUpdatedCatalog() throws {
        let original = store.add(book())
        store.addBookmark(bookID: original.id, chapterIndex: 1, scrollFraction: 0.4, title: "秋日")
        let backup = YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])
        var fetched = original
        fetched.chapters.insert(BookChapter(title: "序言", content: "开篇"), at: 0)
        try store.refreshCatalog(bookID: original.id, fetched: fetched)
        store.removeBookmark(id: store.bookmarks[0].id)
        let result = try backup.merge(into: store, sources: [])
        XCTAssertEqual(result.books, 0)
        XCTAssertEqual(store.bookmarks[0].chapterIndex, 2)
    }

    func testRestoreDiskFailureDoesNotPublishPartialLibrary() throws {
        let original = book()
        var snapshot = store.snapshot
        snapshot.books = [original]
        let backup = YueduLibraryBackup(library: snapshot, sourceURLs: [:])
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try backup.merge(into: store, sources: []))
        XCTAssertTrue(store.books.isEmpty)
    }

    func testRestoreRejectsSourceIDCollisionBeforeChangingLibrary() throws {
        let original = book()
        var snapshot = store.snapshot
        snapshot.books = [original]
        let backup = YueduLibraryBackup(library: snapshot, sourceURLs: [
            original.sourceID!.uuidString: "https://original.example"
        ])
        var unrelated = BookSource.example
        unrelated.id = original.sourceID!
        unrelated.bookSourceUrl = "https://unrelated.example"
        XCTAssertThrowsError(try backup.merge(into: store, sources: [unrelated]))
        XCTAssertTrue(store.books.isEmpty)
    }

    func testBackupRestoresBookmarksWithRepeatedChapterTitles() throws {
        var original = book()
        original.chapters = [
            BookChapter(title: "正文", content: "一"),
            BookChapter(title: "正文", content: "二")
        ]
        store.add(original)
        store.addBookmark(bookID: original.id, chapterIndex: 1, scrollFraction: 0.4, title: "第二个正文")
        let backup = try YueduLibraryBackup.decode(JSONEncoder().encode(
            YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])
        ))
        let destination = LibraryStore(directory: directory.appendingPathComponent("duplicate-titles"), seed: false)
        let result = try backup.merge(into: destination, sources: [])
        XCTAssertEqual(result.bookmarks, 1)
        XCTAssertEqual(destination.bookmarks[0].chapterIndex, 1)
    }
}
