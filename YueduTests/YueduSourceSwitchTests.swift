import XCTest
@testable import Yuedu

@MainActor
final class YueduSourceSwitchTests: XCTestCase {
    private var directory: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LibraryStore(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(store.snapshot)
    }

    private func chapter(_ title: String) -> BookChapter { BookChapter(title: title, content: "") }

    private func book(_ titles: [String] = ["第一章 初见", "第二章 重逢", "番外"]) -> Book {
        Book(title: "换源测试", author: "作者", summary: "", category: "玄幻", coverColor: "517A65",
             coverSymbol: "book", chapters: titles.map(chapter), sourceName: "测试源",
             sourceID: UUID(), bookURL: "https://fixture.invalid/book")
    }

    private func seeded() -> Book {
        var original = book()
        original.chapters[0].content = "原源缓存"
        _ = store.add(original)
        store.updateProgress(bookID: original.id, chapterIndex: 1, scrollFraction: 0.43)
        store.addBookmark(bookID: original.id, chapterIndex: 0, scrollFraction: 0.2, title: "初见书签")
        store.addBookmark(bookID: original.id, chapterIndex: 2, scrollFraction: 0.4, title: "番外书签")
        return store.book(id: original.id)!
    }

    private func perform(_ original: Book, target: Book, copy: Bool = true) throws -> Book {
        try store.switchSource(original: original, candidate: target, chapterIndex: 1,
                               fraction: 0.43, verifiedText: "新源真实正文", copyBookmarks: copy)
    }

    func testMatchesChineseArabicFullWidthAndBoundaryPunctuation() {
        for (old, new) in [("第十二章 初见", "第１２章：初见"),
                           ("第一百零二章　重逢", "第102章 重逢"),
                           ("第一万零三章 初见", "第10003章 初见"),
                           ("第二〇二章 初见", "第202章 初见")] {
            let match = YueduSourceSwitch.match(chapter(old), in: [chapter("序章"), chapter(new)])
            XCTAssertEqual(match?.index, 1, old)
        }
        XCTAssertEqual(YueduSourceSwitch.match(chapter("番 外"), in: [chapter("番外")])?.index, 0)
    }

    func testChapterNumberAloneDifferentSubtitleAndSplitVolumeNeverAutoMatch() {
        for (old, new) in [("第十章", "第10章"), ("第一章", "第一章"), ("第十章 初见", "第10章 重逢"),
                           ("第十章 初见", "第10章 初见（上）"),
                           ("第一卷 第十章 初见", "第二卷 第10章 初见"), ("", "")] {
            XCTAssertNil(YueduSourceSwitch.match(chapter(old), in: [chapter(new)]))
        }
        XCTAssertEqual(YueduSourceSwitch.suggestedIndex(chapter("第十章 初见"), in: [chapter("第10章 重逢")]), 0)
    }

    func testDuplicateMatchesAndManyToOneBookmarksRemainUnmapped() {
        XCTAssertNil(YueduSourceSwitch.match(chapter("第十章 初见"), in: [chapter("第10章 初见"), chapter("第10章：初见")]))
        XCTAssertNil(YueduSourceSwitch.match(chapter("番外"), in: [chapter("番外"), chapter("番外")]))
        XCTAssertTrue(YueduSourceSwitch.bookmarkMapping(from: book(["第一章 初见", "第1章 初见"]),
                                                       to: book(["第1章 初见"])).isEmpty)
    }

    func testUnknownOrDifferentAuthorAndTitleAreFlagged() {
        XCTAssertFalse(YueduSourceSwitch.authorsAgree("佚名", "佚名"))
        XCTAssertFalse(YueduSourceSwitch.authorsAgree("", ""))
        XCTAssertFalse(YueduSourceSwitch.authorsAgree("作者甲", "作者乙"))
        XCTAssertTrue(YueduSourceSwitch.authorsAgree("作者 甲", "作者甲"))
        var target = book()
        target.title = "另一本书"
        XCTAssertFalse(YueduSourceSwitch.metadataAgrees(book(), target))
    }

    func testSwitchPersistsMetadataBookmarksPreviewAndKeepsOriginal() throws {
        var original = seeded()
        let group = try store.saveShelfGroup(name: "玄幻")
        try store.organizeBooks([original.id]) { $0.groupID = group.id; $0.pinned = true; $0.state = .reading }
        try store.setFollowing([original.id], enabled: false)
        original = store.book(id: original.id)!
        let target = book(["第1章：初见", "第2章 重逢"])
        let saved = try perform(original, target: target)
        XCTAssertEqual(saved.shelf, original.shelf)
        XCTAssertFalse(saved.isFollowing)
        XCTAssertEqual(saved.progress, original.progress)
        XCTAssertEqual(saved.chapters[0].content, "")
        XCTAssertEqual(saved.chapters[1].content, "新源真实正文")
        XCTAssertEqual(store.bookmarks.filter { $0.bookID == saved.id }.count, 1)
        XCTAssertEqual(store.bookmarks.first { $0.bookID == saved.id }?.scrollFraction, 0.2)
        let retained = try XCTUnwrap(store.book(id: original.id))
        XCTAssertEqual(retained.chapters, original.chapters)
        XCTAssertEqual(retained.progress, original.progress)
        XCTAssertEqual(store.bookmarks.filter { $0.bookID == original.id }.count, 2)
        let reopened = LibraryStore(directory: directory)
        XCTAssertEqual(reopened.book(id: saved.id), saved)
        XCTAssertEqual(reopened.editions(of: saved).map(\.id), [original.id])
    }

    func testExistingEditionKeepsItsMetadataCacheAndDoesNotDuplicateBookmarks() throws {
        let original = seeded()
        var target = book(["第1章 初见", "第2章 重逢"])
        target.shelf = YueduBookShelfInfo(pinned: false, state: .finished)
        target.chapters[0].content = "已有版本缓存"
        target = store.add(target)
        store.addBookmark(bookID: target.id, chapterIndex: 0, scrollFraction: 0.2, title: "已有书签")
        let saved = try perform(original, target: target)
        XCTAssertEqual(saved.id, target.id)
        XCTAssertEqual(store.books.count, 2)
        XCTAssertEqual(saved.shelf, target.shelf)
        XCTAssertEqual(saved.chapters[0].content, "已有版本缓存")
        XCTAssertEqual(store.bookmarks.filter { $0.bookID == saved.id }.count, 1)
        _ = try perform(store.book(id: original.id)!, target: saved)
        XCTAssertEqual(store.books.count, 2)
        XCTAssertEqual(store.bookmarks.filter { $0.bookID == saved.id }.count, 1)
    }

    func testManualStartAndDisablingBookmarkCopy() throws {
        let original = seeded()
        let saved = try store.switchSource(original: original, candidate: book(), chapterIndex: 0,
                                            fraction: 0, verifiedText: "正文", copyBookmarks: false)
        XCTAssertEqual(saved.progress, ReadingProgress())
        XCTAssertTrue(store.bookmarks.filter { $0.bookID == saved.id }.isEmpty)
    }

    func testStaleOriginalAndTargetCannotOverwriteNewProgress() throws {
        let original = seeded()
        store.updateProgress(bookID: original.id, chapterIndex: 0, scrollFraction: 0.6)
        XCTAssertThrowsError(try perform(original, target: book()))
        let fresh = store.book(id: original.id)!
        let target = store.add(book())
        store.updateProgress(bookID: target.id, chapterIndex: 0, scrollFraction: 0.7)
        XCTAssertThrowsError(try perform(fresh, target: target))
        XCTAssertEqual(store.book(id: target.id)?.progress.scrollFraction, 0.7)
        XCTAssertEqual(store.books.count, 2)
    }

    func testDeletedSavedEditionDoesNotReappear() throws {
        let original = seeded()
        let target = store.add(book())
        store.remove(id: target.id)
        XCTAssertThrowsError(try store.switchSource(original: original, candidate: target, chapterIndex: 0,
                                                   fraction: 0, verifiedText: "正文", copyBookmarks: true,
                                                   candidateWasSaved: true))
        XCTAssertEqual(store.books.count, 1)
    }

    func testEmptyPreviewAndInvalidProgressCannotMutateLibrary() throws {
        let original = seeded()
        let before = try snapshotData()
        for (index, fraction, text) in [(0, 0.0, " \n"), (100, 0.0, "正文"), (0, Double.nan, "正文"), (0, 2.0, "正文")] {
            XCTAssertThrowsError(try store.switchSource(original: original, candidate: book(), chapterIndex: index,
                                                       fraction: fraction, verifiedText: text, copyBookmarks: true))
        }
        XCTAssertEqual(try snapshotData(), before)
    }

    func testWriteFailureLeavesAllLiveDataUntouched() throws {
        let original = seeded()
        let before = try snapshotData()
        let file = directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try perform(original, target: book()))
        XCTAssertEqual(try snapshotData(), before)
        XCTAssertNil(store.book(id: original.id)?.editionGroupID)
    }

    func testEditionGroupsMergeAndRemovingOriginalKeepsOtherVersionsRelated() throws {
        let original = seeded()
        let first = try perform(original, target: book())
        let second = try perform(first, target: book())
        XCTAssertEqual(store.editions(of: second).count, 2)
        store.remove(id: original.id)
        XCTAssertEqual(store.editions(of: second).map(\.id), [first.id])
        let other = store.add(book())
        let otherEdition = try perform(other, target: book())
        _ = try perform(store.book(id: first.id)!, target: otherEdition)
        XCTAssertEqual(store.editions(of: store.book(id: second.id)!).count, 3)
    }

    func testLegacyBookDecodesWithoutEditionMetadata() throws {
        let original = book()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Book.self, from: data)
        XCTAssertNil(restored.editionGroupID)
    }

    func testBackupReconnectsEditionsToExistingBookAndIsIdempotent() throws {
        let original = seeded()
        let saved = try perform(original, target: book())
        let backup = YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])
        let targetDirectory = directory.appendingPathComponent("restore")
        let destination = LibraryStore(directory: targetDirectory)
        var existing = original
        existing.id = UUID()
        _ = destination.add(existing)
        _ = try backup.merge(into: destination, sources: [])
        let restored = try XCTUnwrap(destination.book(id: saved.id))
        XCTAssertEqual(destination.editions(of: restored).map(\.id), [existing.id])
        _ = try backup.merge(into: destination, sources: [])
        XCTAssertEqual(destination.books.count, 2)
        XCTAssertEqual(destination.editions(of: destination.book(id: saved.id)!).map(\.id), [existing.id])
    }

    func testLargeCatalogBookmarkMappingUsesUniqueChapterIdentities() {
        let old = book((1...5_000).map { "第\($0)章 标题\($0)" })
        let new = book(["序章"] + (1...5_000).map { "第\($0)章：标题\($0)" })
        let mapping = YueduSourceSwitch.bookmarkMapping(from: old, to: new)
        XCTAssertEqual(mapping.count, 5_000)
        XCTAssertEqual(mapping[4_999], 5_000)
    }
}
