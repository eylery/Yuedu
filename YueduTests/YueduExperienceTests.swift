import XCTest
import UIKit
@testable import Yuedu

@MainActor
final class YueduExperienceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "Yuedu.experience.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func book(chapters: Int = 2) -> Book {
        Book(title: "体验测试", author: "作者", summary: "", category: "", coverColor: "456C53",
             coverSymbol: "book", chapters: (0..<chapters).map { BookChapter(title: "第\($0)章", content: "正文") }, sourceName: "本地")
    }

    private func source(_ name: String) -> BookSource {
        var source = BookSource.example
        source.id = UUID()
        source.bookSourceName = name
        source.bookSourceUrl = "https://fixture.invalid/\(source.id)"
        source.enabled = true
        return source
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待操作超时")
    }

    func testProgressAndStatisticsDoNotRewriteCatalogAndSurviveRestart() throws {
        let store = LibraryStore(directory: directory)
        let saved = store.add(book(chapters: 1_000))
        let metadata = directory.appendingPathComponent("library.json")
        let before = try Data(contentsOf: metadata)
        for index in 1...8 {
            XCTAssertTrue(store.updateProgress(bookID: saved.id, chapterIndex: 700, scrollFraction: Double(index) / 10))
        }
        XCTAssertTrue(store.recordReading(seconds: 95))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertLessThan(try Data(contentsOf: directory.appendingPathComponent("reading-state.json")).count, 2_000)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.book(id: saved.id)?.progress, ReadingProgress(chapterIndex: 700, scrollFraction: 0.8))
        XCTAssertEqual(restored.readingSeconds, 95)
    }

    func testFailedCheckpointKeepsPendingPositionAndRetriesWithoutLosingStatistics() throws {
        let store = LibraryStore(directory: directory)
        let saved = store.add(book())
        let checkpoint = directory.appendingPathComponent("reading-state.json")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        XCTAssertFalse(store.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.65))
        XCTAssertFalse(store.recordReading(seconds: 35))
        XCTAssertNotNil(store.readingSaveError)
        XCTAssertEqual(store.book(id: saved.id)?.progress.chapterIndex, 0)
        XCTAssertEqual(store.resumeProgress(for: saved), ReadingProgress(chapterIndex: 1, scrollFraction: 0.65))
        try FileManager.default.removeItem(at: checkpoint)
        XCTAssertTrue(store.retryReadingSaves())
        XCTAssertNil(store.readingSaveError)
        XCTAssertTrue(store.pendingPositions.isEmpty)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.book(id: saved.id)?.progress.scrollFraction, 0.65)
        XCTAssertEqual(restored.readingSeconds, 35)
    }

    func testSamePositionStillUpdatesReadingStateAndUnreadChapters() throws {
        let store = LibraryStore(directory: directory)
        let saved = store.add(book())
        XCTAssertTrue(store.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.7))
        var changed = store.snapshot
        changed.books[0].shelf = YueduBookShelfInfo(state: .wanted)
        changed.books[0].following = YueduFollowingInfo(unreadChapterIDs: [saved.chapters[0].id])
        try store.commit(changed)
        XCTAssertTrue(store.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.7))
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.books[0].readingState, .reading)
        XCTAssertEqual(restored.books[0].unreadUpdateCount, 0)
    }

    func testOldCheckpointCannotOverwriteNewCatalogGeneration() throws {
        let store = LibraryStore(directory: directory)
        let saved = store.add(book())
        XCTAssertTrue(store.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.6))
        let checkpoint = directory.appendingPathComponent("reading-state.json")
        let old = try Data(contentsOf: checkpoint)
        var changed = store.snapshot
        changed.books[0].progress = ReadingProgress(chapterIndex: 0, scrollFraction: 0.2)
        try store.commit(changed)
        try old.write(to: checkpoint) // Crash recovery may leave an old sidecar behind.
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.books[0].progress, changed.books[0].progress)
    }

    func testCorruptCheckpointPreservesFilesAndShowsRecoverableLibrary() throws {
        let store = LibraryStore(directory: directory)
        let saved = store.add(book())
        XCTAssertTrue(store.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.7))
        XCTAssertTrue(store.addBookmark(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.7, title: "当前位置"))
        let checkpoint = directory.appendingPathComponent("reading-state.json")
        let corrupt = Data("unreadable progress".utf8)
        try corrupt.write(to: checkpoint)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.books.count, 1)
        XCTAssertNotNil(restored.persistenceError)
        XCTAssertFalse(restored.updateProgress(bookID: saved.id, chapterIndex: 1, scrollFraction: 0.7))
        XCTAssertEqual(try Data(contentsOf: checkpoint), corrupt)
    }

    func testPreferencesRememberFastSourcesAndScopeButRejectEditedRules() {
        let fast = source("快")
        let slow = source("慢")
        let preferences = YueduSearchPreferences(defaults: defaults)
        preferences.scope = [fast.id]
        preferences.record(fast, duration: 0.2, succeeded: true)
        preferences.record(slow, duration: 12, succeeded: false)
        let restored = YueduSearchPreferences(defaults: defaults)
        XCTAssertEqual(restored.scope, [fast.id])
        XCTAssertEqual(restored.priority(for: fast).0, 0)
        XCTAssertEqual(restored.priority(for: slow).0, 2)
        var edited = fast
        edited.searchUrl += "?changed=1"
        XCTAssertEqual(restored.priority(for: edited).0, 1)
        restored.scope = nil
        XCTAssertNil(YueduSearchPreferences(defaults: defaults).scope)
    }

    func testSearchStartsWithTwelveSourcesAndExpandsWithoutDroppingResults() async throws {
        let sources = (0..<18).map { source("书源\($0)") }
        let preferences = YueduSearchPreferences(defaults: defaults)
        preferences.record(sources[17], duration: 0.1, succeeded: true)
        var requested: [UUID] = []
        let model = YueduOnlineSearchModel(preferences: preferences) { source, _, _ in
            requested.append(source.id)
            return [SourceSearchResult(sourceID: source.id, sourceName: source.bookSourceName,
                                       title: "同书", author: "作者", summary: "", bookURL: source.bookSourceUrl + "/book")]
        }
        model.search("同书", sources: sources)
        try await eventually { !model.isSearching }
        XCTAssertEqual(requested.count, 12)
        XCTAssertEqual(requested.first, sources[17].id)
        XCTAssertEqual(model.remainingSourceCount, 6)
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertEqual(Set(requested).count, 18)
        XCTAssertEqual(model.results.count, 18)
        XCTAssertEqual(model.remainingSourceCount, 0)
    }

    func testBookChoiceSurvivesSourceSwitchAndControllerRecreation() {
        let source = source("同源")
        let first = SourceSearchResult(sourceID: source.id, sourceName: source.bookSourceName,
                                      title: "《西游记》", author: "（明）吴承恩", summary: "", bookURL: "/1")
        let second = SourceSearchResult(sourceID: source.id, sourceName: source.bookSourceName,
                                       title: "西游记", author: "吴承恩", summary: "", bookURL: "/2")
        YueduBookChoices(defaults: defaults).remember(second)
        let restored = YueduBookChoices(defaults: defaults)
        XCTAssertEqual(restored.preferred(in: [first, second])?.id, second.id)
        XCTAssertNil(restored.preferred(in: [first]), "Removed records must never be resurrected")
    }

    func testConcurrentReaderAndPrefetchShareRequestAndCancellationIsIndependent() async throws {
        let book = book()
        let source = source("共享请求")
        var continuation: CheckedContinuation<String, Never>?
        var count = 0
        let requests = YueduChapterRequests { _, _, _ in
            count += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { try await requests.load(book.chapters[0], book: book, source: source, revision: 0) }
        let second = Task { try await requests.load(book.chapters[0], book: book, source: source, revision: 0) }
        try await eventually { continuation != nil }
        for _ in 0..<5 { await Task.yield() }
        first.cancel()
        continuation?.resume(returning: "共享正文")
        let text = try await second.value
        XCTAssertEqual(text, "共享正文")
        XCTAssertEqual(count, 1)
        do { _ = try await first.value; XCTFail("Cancelled consumer must not receive content") }
        catch is CancellationError { }
    }

    func testPrefetchSettingAndDarkPalette() {
        var preferences = ReaderPreferences.load(defaults: defaults)
        XCTAssertTrue(preferences.prefetchNextChapter)
        preferences.prefetchNextChapter = false
        preferences.save(defaults: defaults)
        XCTAssertFalse(ReaderPreferences.load(defaults: defaults).prefetchNextChapter)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertNotEqual(Theme.bg.resolvedColor(with: dark), Theme.bg.resolvedColor(with: light))
        XCTAssertNotEqual(Theme.ink.resolvedColor(with: dark), Theme.ink.resolvedColor(with: light))
    }
}
