import XCTest
import CoreText
@testable import Yuedu

@MainActor
final class YueduReadingAndDownloadTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPaginationCoversChineseEmojiAndParagraphsWithoutLosingText() {
        let prefs = ReaderPreferences(fontSize: 23, lineSpacing: 11, paper: .ivory)
        let text = prefs.attributedText(String(repeating: "书页里的春天，👨‍👩‍👧‍👦 一起读书。e\u{301} — 🌱\n下一段的文字。\n", count: 100))
        let size = CGSize(width: 320, height: 500)
        let pages = YueduPagination.ranges(for: text, size: size)
        XCTAssertGreaterThan(pages.count, 2)
        let joined = pages.map { (text.string as NSString).substring(with: $0) }.joined()
        XCTAssertEqual(joined, text.string)
        for (index, range) in pages.enumerated() {
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertEqual(range.location, index == 0 ? 0 : NSMaxRange(pages[index - 1]))
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),
                                                CFRange(location: range.location, length: range.length),
                                                CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
            XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, range.length, "Every saved range must actually fit its paper.")
        }
    }

    func testRepaginationKeepsCharacterAnchorAndLargerTypeAddsPages() {
        let source = String(repeating: "晨光落在树叶上。让每一个字都留在纸间。\n", count: 300)
        let small = ReaderPreferences(fontSize: 16, lineSpacing: 5, paper: .white).attributedText(source)
        let large = ReaderPreferences(fontSize: 30, lineSpacing: 18, paper: .night).attributedText(source)
        let old = YueduPagination.ranges(for: small, size: CGSize(width: 340, height: 600))
        let new = YueduPagination.ranges(for: large, size: CGSize(width: 600, height: 260))
        XCTAssertGreaterThan(new.count, old.count)
        let offset = old[old.count / 2].location
        XCTAssertTrue(NSLocationInRange(offset, new[YueduPagination.page(containing: offset, in: new)]))
    }

    func testPaginationHandlesEmptyAndFractionBoundaries() {
        XCTAssertTrue(YueduPagination.ranges(for: NSAttributedString(string: ""), size: CGSize(width: 300, height: 400)).isEmpty)
        XCTAssertTrue(YueduPagination.ranges(for: NSAttributedString(string: "文字"), size: .zero).isEmpty)
        XCTAssertEqual(YueduPagination.page(for: .nan, count: 10), 0)
        XCTAssertEqual(YueduPagination.page(for: -2, count: 10), 0)
        XCTAssertEqual(YueduPagination.page(for: 3, count: 10), 9)
        XCTAssertEqual(YueduPagination.page(for: .greatestFiniteMagnitude, count: 10), 9)
        XCTAssertEqual(YueduPagination.page(for: 0.5, count: 11), 5)
    }

    func testTurnStylePreferencePersistsAndUnknownValueFallsBack() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        ReaderPreferences(fontSize: 26, lineSpacing: 9, paper: .night, turnStyle: .curl).save(defaults: defaults)
        XCTAssertEqual(ReaderPreferences.load(defaults: defaults).turnStyle, .curl)
        defaults.set("unrecognized", forKey: "reader.turnStyle")
        XCTAssertEqual(ReaderPreferences.load(defaults: defaults).turnStyle, .scroll)
    }

    private func book() -> Book {
        Book(title: "后台测试", author: "作者", summary: "", category: "测试", coverColor: "456C53", coverSymbol: "book",
             chapters: [
                BookChapter(title: "一", content: "", url: "https://example.com/1"),
                BookChapter(title: "二", content: "", url: "https://example.com/2")
             ], sourceName: "测试", sourceID: UUID(), bookURL: "https://example.com/book")
    }

    func testBackgroundSuspendsParserButForegroundResumesPersistedQueue() async throws {
        let library = LibraryStore(directory: directory, seed: false)
        let original = library.add(book())
        let started = expectation(description: "chapter started")
        var calls = 0
        let manager = YueduDownloadManager(library: library, observeBackground: false,
                                           queueFile: directory.appendingPathComponent("queue.json")) { _, _ in
            calls += 1
            if calls == 1 {
                started.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return "已下载正文"
        }
        manager.start(bookID: original.id)
        await fulfillment(of: [started], timeout: 2)
        manager.enterBackground()
        await manager.waitUntilIdle()
        XCTAssertTrue(manager.status(for: original.id)!.isRunning)
        XCTAssertEqual(library.book(id: original.id)?.cachedChapterCount, 0)
        manager.enterForeground()
        await manager.waitUntilIdle()
        XCTAssertEqual(library.book(id: original.id)?.cachedChapterCount, 2)
        XCTAssertEqual(manager.status(for: original.id)?.message, "缓存完成")
    }

    func testQueueRestoresSelectedChapterIDsAcrossRelaunchAndCatalogInsertion() async throws {
        let library = LibraryStore(directory: directory, seed: false)
        let original = library.add(book())
        let queueFile = directory.appendingPathComponent("queue.json")
        var manager: YueduDownloadManager? = YueduDownloadManager(
            library: library, observeBackground: false, queueFile: queueFile
        ) { _, _ in XCTFail("Must not parse in background"); return "" }
        manager?.enterBackground()
        manager?.start(bookID: original.id, startIndex: 1, limit: 1)
        manager = nil
        var refreshed = original
        refreshed.chapters.insert(BookChapter(title: "序章", content: "", url: "https://example.com/0"), at: 0)
        try library.refreshCatalog(bookID: original.id, fetched: refreshed)
        var requested: [UUID] = []
        let restored = YueduDownloadManager(library: library, observeBackground: false, queueFile: queueFile) { chapter, _ in
            requested.append(chapter.id)
            return "恢复后的正文"
        }
        await restored.waitUntilIdle()
        XCTAssertEqual(requested, [original.chapters[1].id])
        XCTAssertEqual(library.book(id: original.id)?.chapters[2].content, "恢复后的正文")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: queueFile)) as? [String], [])
    }

    func testUserPauseRemovesDurableRequest() async throws {
        let library = LibraryStore(directory: directory, seed: false)
        let original = library.add(book())
        let queueFile = directory.appendingPathComponent("queue.json")
        let manager = YueduDownloadManager(library: library, observeBackground: false, queueFile: queueFile) { _, _ in "" }
        manager.enterBackground()
        manager.start(bookID: original.id)
        manager.pause(bookID: original.id)
        let restored = YueduDownloadManager(library: library, observeBackground: false, queueFile: queueFile) { _, _ in
            XCTFail("User-paused downloads must not restart")
            return ""
        }
        await restored.waitUntilIdle()
        XCTAssertNil(restored.status(for: original.id))
    }

    func testTransferManifestDeduplicatesAndPersistsCancellation() throws {
        let service = YueduBackgroundTransfer(directory: directory, configuration: .ephemeral)
        let original = book()
        let request = URLRequest(url: URL(string: original.chapters[0].url!)!)
        let plan = YueduBackgroundTransfer.Plan(bookID: original.id, chapterID: original.chapters[0].id,
                                                sourceID: original.sourceID!, request: request)
        try service.enqueue([plan, plan])
        XCTAssertEqual(service.summary(bookID: original.id).waiting, 1)
        let reloaded = YueduBackgroundTransfer(directory: directory, configuration: .ephemeral)
        XCTAssertEqual(reloaded.summary(bookID: original.id).waiting, 1)
        reloaded.remove(bookID: original.id)
        let cancelled = YueduBackgroundTransfer(directory: directory, configuration: .ephemeral)
        XCTAssertEqual(cancelled.summary(bookID: original.id).waiting, 0)
    }

    func testTransferFingerprintSeparatesSourceHeadersAndBody() {
        let source = UUID()
        var first = URLRequest(url: URL(string: "https://example.com/chapter")!)
        first.setValue("reader", forHTTPHeaderField: "User-Agent")
        var second = first
        XCTAssertEqual(YueduBackgroundTransfer.fingerprint(first, sourceID: source),
                       YueduBackgroundTransfer.fingerprint(second, sourceID: source))
        second.setValue("different", forHTTPHeaderField: "User-Agent")
        XCTAssertNotEqual(YueduBackgroundTransfer.fingerprint(first, sourceID: source),
                          YueduBackgroundTransfer.fingerprint(second, sourceID: source))
        XCTAssertNotEqual(YueduBackgroundTransfer.fingerprint(first, sourceID: source),
                          YueduBackgroundTransfer.fingerprint(first, sourceID: UUID()))
        second = first
        second.httpMethod = "POST"
        second.httpBody = Data("different".utf8)
        XCTAssertNotEqual(YueduBackgroundTransfer.fingerprint(first, sourceID: source),
                          YueduBackgroundTransfer.fingerprint(second, sourceID: source))
    }

    func testBackgroundPlannerKeepsDynamicAuthenticatedAndRateLimitedRequestsInForeground() throws {
        let sources = SourceStore(directory: directory)
        var source = BookSource.example
        source.enabled = true
        try sources.save(source)
        let state = LegadoStateStore(directory: directory)
        let engine = SourceEngine(session: URLSession(configuration: .ephemeral), store: sources, stateStore: state)
        var original = book()
        original.sourceID = source.id
        func plans() -> [YueduBackgroundTransfer.Plan] {
            engine.backgroundPlans(book: original, chapters: original.chapters)
        }
        XCTAssertEqual(plans().count, 2)
        original.chapters[0].url = "https://example.com/1,{\"method\":\"POST\",\"body\":\"x=1\"}"
        XCTAssertEqual(plans().count, 1)
        for (field, value) in [
            ("header", #"{"Authorization":"secret"}"#),
            ("header", "@js:JSON.stringify({Authorization:'secret'})"),
            ("jsLib", "https://example.com/library.js"),
            ("concurrentRate", "2000")
        ] {
            source.rawFields = [field: .string(value)]
            try sources.save(source)
            XCTAssertTrue(plans().isEmpty, field)
        }
        source.rawFields = [:]
        try sources.save(source)
        try state.save(["loginHeaders": ["Cookie": "session=test"]], for: source.id)
        XCTAssertTrue(plans().isEmpty)
    }
}
