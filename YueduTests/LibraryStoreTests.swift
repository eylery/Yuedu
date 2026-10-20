import XCTest
@testable import Yuedu

@MainActor
final class LibraryStoreTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private func makeBook() -> Book {
        Book(title: "测试书籍", author: "作者", summary: "简介", category: "测试", coverColor: "456C53", coverSymbol: "book", chapters: [BookChapter(title: "一", content: "正文"), BookChapter(title: "二", content: "正文二")], sourceName: "TXT")
    }
    func testLibraryPersistsProgressBookmarksAndStats() throws {
        let store = LibraryStore(directory: directory, seed: false)
        let book = store.add(makeBook())
        store.updateProgress(bookID: book.id, chapterIndex: 1, scrollFraction: 0.4)
        store.addBookmark(bookID: book.id, chapterIndex: 1, scrollFraction: 0.4, title: "二")
        store.recordReading(seconds: 65)
        let restored = LibraryStore(directory: directory, seed: false)
        XCTAssertEqual(restored.books.count, 1)
        XCTAssertEqual(restored.books[0].progress.chapterIndex, 1)
        XCTAssertEqual(restored.books[0].fractionRead, 0.7, accuracy: 0.0001)
        XCTAssertEqual(restored.bookmarks.count, 1)
        XCTAssertEqual(restored.readingSeconds, 65)
        XCTAssertEqual(restored.readingDates.count, 1)
        XCTAssertNil(restored.persistenceError)
    }
    func testDuplicateImportAndRemoval() {
        let store = LibraryStore(directory: directory, seed: false)
        let book = store.add(makeBook())
        XCTAssertEqual(store.add(makeBook()).id, book.id)
        store.addBookmark(bookID: book.id, chapterIndex: 0, scrollFraction: 0.2, title: "一")
        store.remove(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertTrue(store.bookmarks.isEmpty)
    }
    func testProgressClampsToExistingChapters() {
        let store = LibraryStore(directory: directory, seed: false)
        let book = store.add(makeBook())
        store.updateProgress(bookID: book.id, chapterIndex: 99, scrollFraction: 3)
        XCTAssertEqual(store.book(id: book.id)?.progress.chapterIndex, 1)
        XCTAssertEqual(store.book(id: book.id)?.fractionRead, 1)
        store.updateProgress(bookID: book.id, chapterIndex: -2, scrollFraction: -0.5)
        XCTAssertEqual(store.book(id: book.id)?.fractionRead, 0)
    }
    func testCorruptLibraryIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        let original = Data("not a valid library".utf8)
        try original.write(to: file)
        let store = LibraryStore(directory: directory)
        XCTAssertNotNil(store.persistenceError)
        store.add(makeBook())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testInitialSeedingDoesNotNotifyBeforeStoreIsInitialized() {
        let notification = expectation(description: "No reentrant notification during initialization")
        notification.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { _ in notification.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let store = LibraryStore(directory: directory, seed: true)
        XCTAssertEqual(store.books.count, 6)
        wait(for: [notification], timeout: 0.05)
    }
}
