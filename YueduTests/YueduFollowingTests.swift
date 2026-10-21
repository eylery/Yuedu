import XCTest
import UIKit
@testable import Yuedu

@MainActor
final class YueduFollowingTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LibraryStore(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func online(_ title: String = "连载小说") -> Book {
        Book(title: title, author: "测试", summary: "", category: "玄幻", coverColor: "517A65",
             coverSymbol: "book", chapters: [BookChapter(title: "第一章", content: "缓存正文", url: "/1")],
             sourceName: "测试书源", sourceID: UUID(), bookURL: "https://fixture.invalid/\(title)")
    }

    private func appended(_ book: Book) -> Book {
        var fetched = book
        fetched.chapters = [BookChapter(title: "第一章", content: "", url: "/1"),
                            BookChapter(title: "第二章", content: "", url: "/2"),
                            BookChapter(title: "第三章", content: "", url: "/3")]
        return fetched
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待追更状态超时", file: file, line: line)
    }

    func testCatalogRefreshAccumulatesWithoutDuplicatesAndPreservesReading() throws {
        let book = store.add(online())
        store.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0.4)
        store.addBookmark(bookID: book.id, chapterIndex: 0, scrollFraction: 0.3, title: "书签")
        XCTAssertEqual(try store.refreshCatalog(bookID: book.id, fetched: appended(book)), 2)
        XCTAssertEqual(try store.refreshCatalog(bookID: book.id, fetched: appended(book)), 0)
        let saved = try XCTUnwrap(store.book(id: book.id))
        XCTAssertEqual(saved.unreadUpdateCount, 2)
        XCTAssertEqual(saved.progress.scrollFraction, 0.4)
        XCTAssertEqual(saved.chapters[0].content, "缓存正文")
        XCTAssertEqual(saved.chapters[0].id, book.chapters[0].id)
        XCTAssertEqual(store.bookmarks.first?.chapterIndex, 0)
        XCTAssertNotNil(saved.following?.updatedAt)
        XCTAssertNotNil(saved.following?.checkedAt)
    }

    func testReadProgressConsumesOnlyReachedUpdatesAndClearKeepsProgress() throws {
        let book = store.add(online())
        try store.refreshCatalog(bookID: book.id, fetched: appended(book))
        store.updateProgress(bookID: book.id, chapterIndex: 1, scrollFraction: 0.4)
        XCTAssertEqual(store.book(id: book.id)?.unreadUpdateCount, 2)
        store.updateProgress(bookID: book.id, chapterIndex: 2, scrollFraction: 0.1)
        XCTAssertEqual(store.book(id: book.id)?.unreadUpdateCount, 1)
        store.updateProgress(bookID: book.id, chapterIndex: 2, scrollFraction: 1)
        XCTAssertEqual(store.book(id: book.id)?.unreadUpdateCount, 0)
        store.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0)
        XCTAssertEqual(store.book(id: book.id)?.unreadUpdateCount, 0)
        var more = appended(book)
        more.chapters.append(BookChapter(title: "第四章", content: "", url: "/4"))
        try store.refreshCatalog(bookID: book.id, fetched: more)
        let progress = store.book(id: book.id)?.progress
        try store.clearUpdateMarks([book.id])
        XCTAssertEqual(store.book(id: book.id)?.unreadUpdateCount, 0)
        XCTAssertEqual(store.book(id: book.id)?.progress, progress)
    }

    func testDefaultsPersistenceAndLegacyDecode() throws {
        let book = store.add(online())
        XCTAssertTrue(book.isFollowing)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        legacy.removeValue(forKey: "following")
        XCTAssertTrue(try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: legacy)).isFollowing)
        try store.organizeBooks([book.id]) { $0.state = .finished }
        XCTAssertFalse(store.book(id: book.id)!.isFollowing)
        try store.setFollowing([book.id], enabled: true)
        XCTAssertTrue(store.book(id: book.id)!.isFollowing)
        try store.refreshCatalog(bookID: book.id, fetched: appended(book))
        try store.setFollowing([book.id], enabled: false)
        let restored = LibraryStore(directory: directory)
        XCTAssertFalse(restored.book(id: book.id)!.isFollowing)
        XCTAssertEqual(restored.book(id: book.id)?.unreadUpdateCount, 2)
        var local = online()
        local.sourceID = nil
        XCTAssertFalse(local.canFollow)
        XCTAssertFalse(local.isFollowing)
    }

    func testBatchContinuesAfterFailureAndRetriesClearError() async throws {
        let bad = store.add(online("故障书"))
        let good = store.add(online("正常书"))
        var fail = true
        let manager = YueduFollowingManager(store: store, loader: { book in
            if book.id == bad.id && fail { throw SourceError.network("测试服务离线") }
            return self.appended(book)
        }, sourceAvailable: { _ in true })
        manager.start()
        try await eventually { !manager.isRunning }
        XCTAssertEqual(manager.completed, 2)
        XCTAssertEqual(store.book(id: good.id)?.unreadUpdateCount, 2)
        XCTAssertEqual(store.book(id: bad.id)?.following?.error, "测试服务离线")
        XCTAssertEqual(store.book(id: bad.id)?.chapters.count, 1)
        fail = false
        manager.start(ids: [bad.id])
        try await eventually { !manager.isRunning }
        XCTAssertNil(store.book(id: bad.id)?.following?.error)
        XCTAssertEqual(store.book(id: bad.id)?.unreadUpdateCount, 2)
    }

    func testPausedLocalAndFinishedExcludedAndAutomaticThrottled() async throws {
        let active = store.add(online("追更"))
        let paused = store.add(online("暂停"))
        let finished = store.add(online("已读"))
        var local = online("本地")
        local.sourceID = nil
        store.add(local)
        try store.setFollowing([paused.id], enabled: false)
        try store.organizeBooks([finished.id]) { $0.state = .finished }
        var calls: [UUID] = []
        let manager = YueduFollowingManager(store: store, loader: { book in
            calls.append(book.id)
            return book
        }, sourceAvailable: { _ in true })
        manager.start(automatic: true)
        try await eventually { !manager.isRunning }
        XCTAssertEqual(calls, [active.id])
        manager.start(automatic: true)
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(calls.count, 1)
        manager.start(automatic: true, now: Date().addingTimeInterval(31 * 60))
        try await eventually { !manager.isRunning }
        XCTAssertEqual(calls.count, 2)
    }

    func testPauseDuringRequestDiscardsLateCatalog() async throws {
        let book = store.add(online())
        var continuation: CheckedContinuation<Book, Never>?
        let manager = YueduFollowingManager(store: store, loader: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, sourceAvailable: { _ in true })
        manager.start()
        try await eventually { continuation != nil }
        try store.setFollowing([book.id], enabled: false)
        continuation?.resume(returning: appended(book))
        try await eventually { !manager.isRunning }
        XCTAssertEqual(store.book(id: book.id)?.chapters.count, 1)
        XCTAssertNil(store.book(id: book.id)?.following?.checkedAt)
    }

    func testCancellationPreventsLateWriteAndNextBookRequest() async throws {
        let first = store.add(online("一"))
        store.add(online("二"))
        var calls = 0
        var continuation: CheckedContinuation<Book, Never>?
        let manager = YueduFollowingManager(store: store, loader: { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }, sourceAvailable: { _ in true })
        manager.start()
        manager.start()
        try await eventually { continuation != nil }
        manager.cancel()
        continuation?.resume(returning: appended(first))
        try await eventually { !manager.isRunning }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.books.allSatisfy { $0.chapters.count == 1 && $0.following == nil })
    }

    func testDisabledSourceSkipsNetworkAndReportsReason() async throws {
        let book = store.add(online())
        var calls = 0
        let manager = YueduFollowingManager(store: store, loader: { book in calls += 1; return book }, sourceAvailable: { _ in false })
        manager.start()
        try await eventually { !manager.isRunning }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.book(id: book.id)?.following?.error?.contains("书源已停用") == true)
    }

    func testBackupRoundTripPreservesFollowingState() throws {
        let book = store.add(online())
        try store.refreshCatalog(bookID: book.id, fetched: appended(book))
        try store.setFollowing([book.id], enabled: false)
        let backup = YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])
        let decoded = try YueduLibraryBackup.decode(JSONEncoder().encode(backup))
        let restored = LibraryStore(directory: directory.appendingPathComponent("restore"))
        _ = try decoded.merge(into: restored, sources: [])
        XCTAssertEqual(restored.book(id: book.id)?.following, store.book(id: book.id)?.following)
    }

    func testFailedCatalogMergeDoesNotMarkBookAsUpdated() throws {
        let book = store.add(online())
        store.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0.5)
        var invalid = book
        invalid.chapters = [BookChapter(title: "不匹配章节", content: "", url: "/unknown")]
        XCTAssertThrowsError(try store.refreshCatalog(bookID: book.id, fetched: invalid))
        XCTAssertNil(store.book(id: book.id)?.following)
        XCTAssertEqual(store.book(id: book.id)?.chapters, book.chapters)
    }

    func testVisibleReaderKeepsChapterIdentityWhenCatalogInsertsChapters() throws {
        let library = LibraryStore.shared
        let book = library.add(online(UUID().uuidString))
        defer { library.remove(id: book.id) }
        library.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0)
        let reader = ReaderViewController(bookID: book.id)
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.view.layoutIfNeeded()
        var fetched = appended(book)
        fetched.chapters.insert(BookChapter(title: "序章", content: "", url: "/preface"), at: 0)
        try library.refreshCatalog(bookID: book.id, fetched: fetched)
        reader.viewWillDisappear(false)
        XCTAssertEqual(library.book(id: book.id)?.progress.chapterIndex, 1)
        XCTAssertEqual(library.book(id: book.id)?.currentChapterTitle, "第一章")
    }
}
