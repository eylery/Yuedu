import XCTest
@testable import Yuedu

@MainActor
final class YueduCacheManagementTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryStore!
    private var queueFile: URL { directory.appendingPathComponent("queue.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LibraryStore(directory: directory)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func book(cached: Bool = true) -> Book {
        Book(title: "缓存测试", author: "作者", summary: "", category: "小说", coverColor: "517A65", coverSymbol: "book",
             chapters: (0..<5).map { BookChapter(title: "第\($0 + 1)章 测试", content: cached ? "正文\($0)🌱" : "", url: "https://example.com/\($0)") },
             sourceName: "测试源", sourceID: UUID(), bookURL: "https://example.com/book")
    }

    func testSizeCountsUTF8AndReadCleanupProtectsCurrentAndBookmarkChapters() throws {
        let original = store.add(book())
        store.updateProgress(bookID: original.id, chapterIndex: 3, scrollFraction: 0.42)
        store.addBookmark(bookID: original.id, chapterIndex: 1, scrollFraction: 0.5, title: "书签")
        let before = store.book(id: original.id)!
        XCTAssertEqual(before.cacheSummary.bytes, "正文0🌱".utf8.count * 5)
        let removed = try store.clearCachedChapters(bookIDs: [original.id], cleanup: .read)
        XCTAssertEqual(removed.chapters, 2)
        let saved = store.book(id: original.id)!
        XCTAssertTrue(saved.chapters[0].content.isEmpty)
        XCTAssertFalse(saved.chapters[1].content.isEmpty)
        XCTAssertTrue(saved.chapters[2].content.isEmpty)
        XCTAssertFalse(saved.chapters[3].content.isEmpty)
        XCTAssertFalse(saved.chapters[4].content.isEmpty)
        XCTAssertEqual(saved.progress, before.progress)
        XCTAssertEqual(saved.lastReadAt, before.lastReadAt)
        XCTAssertEqual(saved.chapters.map(\.id), before.chapters.map(\.id))
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(LibraryStore(directory: directory).book(id: original.id), saved)
    }

    func testLocalAndSampleBodiesNeverClearAndOnlineMetadataStays() throws {
        var local = book()
        local.sourceID = nil
        local.bookURL = nil
        let localID = store.add(local).id
        var sample = book()
        sample.isSample = true
        let sampleID = store.add(sample).id
        var online = book()
        online.shelf = YueduBookShelfInfo(pinned: true, state: .finished)
        online.following = YueduFollowingInfo(enabled: false)
        online.editionGroupID = UUID()
        let id = store.add(online).id
        let removed = try store.clearCachedChapters(bookIDs: [localID, sampleID, id], cleanup: .all)
        XCTAssertEqual(removed.chapters, 5)
        XCTAssertEqual(store.book(id: localID)?.cachedChapterCount, 5)
        XCTAssertEqual(store.book(id: sampleID)?.cachedChapterCount, 5)
        let saved = store.book(id: id)!
        XCTAssertEqual(saved.shelf, online.shelf)
        XCTAssertEqual(saved.following, online.following)
        XCTAssertEqual(saved.editionGroupID, online.editionGroupID)
        XCTAssertEqual(saved.chapters.map(\.url), online.chapters.map(\.url))
    }

    func testSelectedCleanupPreservesOtherBooksAndRejectsLateForegroundWrite() throws {
        let first = store.add(book())
        let second = store.add(book())
        let revision = store.cacheRevision(for: first.id)
        try store.clearCachedChapters(bookIDs: [first.id], cleanup: .chapters([first.chapters[2].id]))
        XCTAssertEqual(store.book(id: first.id)?.cachedChapterCount, 4)
        XCTAssertEqual(store.book(id: second.id)?.cachedChapterCount, 5)
        XCTAssertFalse(try store.cacheChapterContent(bookID: first.id, chapterID: first.chapters[2].id, text: "迟到的正文", revision: revision))
        XCTAssertTrue(try store.cacheChapterContent(bookID: first.id, chapterID: first.chapters[2].id, text: "主动重新下载", revision: store.cacheRevision(for: first.id)))
    }

    func testCleanupDiskFailureLeavesBodyAndRevisionUnchanged() throws {
        let original = store.add(book())
        let file = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.clearCachedChapters(bookIDs: [original.id], cleanup: .all))
        XCTAssertEqual(store.book(id: original.id), original)
        XCTAssertEqual(store.cacheRevision(for: original.id), 0)
        XCTAssertThrowsError(try store.cacheChapterContent(bookID: original.id, chapterID: original.chapters[0].id, text: "新正文", revision: 0))
        XCTAssertEqual(store.book(id: original.id), original)
    }

    func testPausedRangeSurvivesRestartAndCatalogInsertion() async throws {
        let original = store.add(book(cached: false))
        var manager: YueduDownloadManager? = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { _, _ in
            XCTFail("Background queue must not parse"); return ""
        }
        manager?.enterBackground()
        manager?.start(bookID: original.id, startIndex: 1, limit: 2)
        manager?.pause(bookID: original.id)
        manager = nil
        var refreshed = original
        refreshed.chapters.insert(BookChapter(title: "序章", content: ""), at: 0)
        try store.refreshCatalog(bookID: original.id, fetched: refreshed)
        var calls: [UUID] = []
        let restored = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { chapter, _ in
            calls.append(chapter.id)
            return "下载正文"
        }
        await restored.waitUntilIdle()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(restored.canResume(bookID: original.id))
        restored.resume(bookID: original.id)
        await restored.waitUntilIdle()
        XCTAssertEqual(calls, Array(original.chapters[1...2].map(\.id)))
        XCTAssertEqual(store.book(id: original.id)?.cachedChapterCount, 2)
    }

    func testFailureIDsPersistAndRetryOnlyFailedChaptersInRequestedRange() async throws {
        let original = store.add(book(cached: false))
        var manager: YueduDownloadManager? = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { chapter, _ in
            if chapter.id == original.chapters[1].id { throw SourceError.network("测试失败") }
            return "成功正文"
        }
        manager?.start(bookID: original.id, startIndex: 0, limit: 3)
        await manager?.waitUntilIdle()
        XCTAssertEqual(manager?.status(for: original.id)?.failedCount, 1)
        manager = nil
        var calls: [UUID] = []
        let restored = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { chapter, _ in
            calls.append(chapter.id)
            return "重试成功"
        }
        await restored.waitUntilIdle()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(restored.failedChapterIDs(bookID: original.id), [original.chapters[1].id])
        XCTAssertTrue(restored.status(for: original.id)?.failures.first?.contains("测试失败") == true)
        restored.resume(bookID: original.id, failuresOnly: true)
        await restored.waitUntilIdle()
        XCTAssertEqual(calls, [original.chapters[1].id])
        XCTAssertEqual(store.book(id: original.id)?.cachedChapterCount, 3)
        XCTAssertTrue(restored.failedChapterIDs(bookID: original.id).isEmpty)
    }

    func testClearCancelsQueueAndNonCooperativeLateResultCannotRefill() async throws {
        let original = store.add(book(cached: false))
        let started = expectation(description: "started")
        var continuation: CheckedContinuation<String, Never>?
        let manager = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { _, _ in
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        manager.start(bookID: original.id)
        await fulfillment(of: [started], timeout: 2)
        try manager.clearCache(bookIDs: [original.id], cleanup: .all)
        continuation?.resume(returning: "迟到的下载")
        await manager.waitUntilIdle()
        XCTAssertEqual(store.book(id: original.id)?.cachedChapterCount, 0)
        XCTAssertFalse(manager.taskBookIDs.contains(original.id))
        let restored = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { _, _ in XCTFail(); return "" }
        await restored.waitUntilIdle()
        XCTAssertTrue(restored.taskBookIDs.isEmpty)
    }

    func testPauseThenImmediatelyResumeCannotRemoveNewRequest() async throws {
        let original = store.add(book(cached: false))
        let started = expectation(description: "started")
        var continuation: CheckedContinuation<String, Never>?
        var calls = 0
        let manager = YueduDownloadManager(library: store, observeBackground: false) { _, _ in
            calls += 1
            if calls == 1 {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            return "新任务正文"
        }
        manager.start(bookID: original.id, startIndex: 1, limit: 1)
        await fulfillment(of: [started], timeout: 2)
        manager.pause(bookID: original.id)
        manager.resume(bookID: original.id)
        continuation?.resume(returning: "已取消请求的正文")
        await manager.waitUntilIdle()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.book(id: original.id)?.chapters[1].content, "新任务正文")
        XCTAssertEqual(manager.status(for: original.id)?.message, "缓存完成")
    }

    func testUnreadableQueueIsPreservedAndDoesNotPermitUnsafeCleanup() throws {
        let original = store.add(book())
        let invalid = Data("invalid queue".utf8)
        try invalid.write(to: queueFile)
        let manager = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { _, _ in "" }
        XCTAssertNotNil(manager.queueError)
        manager.start(bookID: original.id)
        XCTAssertEqual(try Data(contentsOf: queueFile), invalid)
        XCTAssertThrowsError(try manager.clearCache(bookIDs: [original.id], cleanup: .all))
        XCTAssertEqual(store.book(id: original.id)?.cachedChapterCount, 5)
    }

    func testCancellationWriteFailureDoesNotClearCachedBodies() throws {
        let original = store.add(book())
        let manager = YueduDownloadManager(library: store, observeBackground: false, queueFile: queueFile) { _, _ in "" }
        manager.enterBackground()
        manager.start(bookID: original.id)
        try FileManager.default.removeItem(at: queueFile)
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.clearCache(bookIDs: [original.id], cleanup: .all))
        XCTAssertEqual(store.book(id: original.id), original)
        XCTAssertTrue(manager.taskBookIDs.contains(original.id))
    }

    func testRemovingBookAlsoRemovesPausedTask() throws {
        let original = store.add(book())
        let manager = YueduDownloadManager(library: store, observeBackground: true, queueFile: queueFile) { _, _ in "" }
        manager.enterBackground()
        manager.start(bookID: original.id)
        manager.pause(bookID: original.id)
        store.remove(id: original.id)
        XCTAssertFalse(manager.taskBookIDs.contains(original.id))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: queueFile)) as? [String], [])
    }
}
