import XCTest
import UIKit
@testable import Yuedu

@MainActor
final class YueduShelfManagementTests: XCTestCase {
    func testHiddenShelfDefersProgressRefreshUntilItAppears() throws {
        let library = LibraryStore.shared
        let saved = library.add(book("隐藏书架刷新验证-\(UUID().uuidString)"))
        defer { library.remove(id: saved.id) }
        let shelf = BookshelfViewController()
        shelf.loadViewIfNeeded()
        shelf.viewWillAppear(false)
        let header = try XCTUnwrap(shelf.content.arrangedSubviews.first)
        shelf.viewWillDisappear(false)
        library.updateProgress(bookID: saved.id, chapterIndex: 0, scrollFraction: 0.4)
        library.recordReading(seconds: 1)
        XCTAssertTrue(shelf.content.arrangedSubviews.first === header,
                      "Reading updates must not rebuild the entire hidden shelf")
        shelf.viewWillAppear(false)
        XCTAssertFalse(shelf.content.arrangedSubviews.first === header,
                       "Returning to the shelf must display the latest stored state")
        shelf.viewWillDisappear(false)
    }

    private var directory: URL!
    private var store: LibraryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = LibraryStore(directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func book(_ title: String = "故事") -> Book {
        Book(title: title, author: "作者", summary: "", category: "", coverColor: "456C53",
             coverSymbol: "book", chapters: [BookChapter(title: "第一章", content: "正文")], sourceName: "TXT")
    }

    func testNewLibraryStartsEmptyAndLegacyLibraryStillLoads() throws {
        XCTAssertTrue(store.books.isEmpty)
        let original = store.add(book())
        store.updateProgress(bookID: original.id, chapterIndex: 0, scrollFraction: 0.4)
        store.addBookmark(bookID: original.id, chapterIndex: 0, scrollFraction: 0.4, title: "保留")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot)) as? [String: Any])
        json.removeValue(forKey: "shelfGroups")
        var books = try XCTUnwrap(json["books"] as? [[String: Any]])
        books[0].removeValue(forKey: "shelf")
        json["books"] = books
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("library.json"))
        let restored = LibraryStore(directory: directory)
        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(restored.books.first?.readingState, .reading)
        XCTAssertEqual(restored.books.first?.progress.scrollFraction, 0.4)
        XCTAssertEqual(restored.bookmarks.count, 1)
        XCTAssertTrue(restored.shelfGroups.isEmpty)
    }

    func testBatchOrganizationPersistsWithoutChangingReadingData() throws {
        let a = store.add(book("甲"))
        let b = store.add(book("乙"))
        store.updateProgress(bookID: a.id, chapterIndex: 0, scrollFraction: 0.3)
        store.addBookmark(bookID: a.id, chapterIndex: 0, scrollFraction: 0.3, title: "位置")
        let group = try store.saveShelfGroup(name: "  正在追更  ")
        try store.organizeBooks([a.id, b.id]) {
            $0.groupID = group.id
            $0.pinned = true
            $0.state = .finished
        }
        store.recordReading(seconds: 20) // Ordinary persistence must also preserve groups.
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.shelfGroups.first?.name, "正在追更")
        XCTAssertEqual(restored.books.filter { $0.shelfInfo.groupID == group.id && $0.shelfInfo.pinned }.count, 2)
        XCTAssertEqual(restored.book(id: a.id)?.progress.scrollFraction, 0.3)
        XCTAssertEqual(restored.bookmarks.count, 1)
        XCTAssertEqual(restored.book(id: a.id)?.readingState, .finished)
    }

    func testGroupRenameValidationAndDeletionPreserveBooks() throws {
        let a = store.add(book())
        let group = try store.saveShelfGroup(name: "小说")
        try store.organizeBooks([a.id]) { $0.groupID = group.id }
        XCTAssertThrowsError(try store.saveShelfGroup(name: " 小说 "))
        XCTAssertThrowsError(try store.saveShelfGroup(name: "  "))
        XCTAssertThrowsError(try store.saveShelfGroup(name: String(repeating: "字", count: 21)))
        try store.saveShelfGroup(name: "追更", id: group.id)
        XCTAssertEqual(store.shelfGroups.first?.name, "追更")
        try store.deleteShelfGroup(id: group.id)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertNil(store.books.first?.shelfInfo.groupID)
        XCTAssertEqual(store.books.first?.chapters.first?.content, "正文")
    }

    func testFailedBatchWriteDoesNotPublishChanges() throws {
        let a = store.add(book())
        let notifications = expectation(description: "no failed change notification")
        notifications.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { _ in notifications.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.organizeBooks([a.id]) { $0.pinned = true })
        XCTAssertThrowsError(try store.removeBooks([a.id]))
        XCTAssertThrowsError(try store.saveShelfGroup(name: "失败"))
        XCTAssertFalse(store.books[0].shelfInfo.pinned)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertTrue(store.shelfGroups.isEmpty)
        awaitNoNotifications(notifications)
    }

    private func awaitNoNotifications(_ expectation: XCTestExpectation) {
        wait(for: [expectation], timeout: 0.05)
    }

    func testBatchRemoveOnlyDeletesSelectedBooksAndTheirBookmarks() throws {
        let a = store.add(book("甲"))
        let b = store.add(book("乙"))
        for item in [a, b] { store.addBookmark(bookID: item.id, chapterIndex: 0, scrollFraction: 0.2, title: item.title) }
        try store.removeBooks([a.id])
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.books.map(\.id), [b.id])
        XCTAssertEqual(restored.bookmarks.map(\.bookID), [b.id])
    }

    func testSampleVisibilityFiltersAndPinnedSort() throws {
        var sample = book("示例")
        sample.isSample = true
        let a = store.add(sample)
        let b = store.add(book("乙"))
        let c = store.add(book("丙"))
        XCTAssertEqual(YueduShelfQuery.books(store.books).count, 2)
        XCTAssertEqual(YueduShelfQuery.books(store.books, showSamples: true).count, 3)
        let group = try store.saveShelfGroup(name: "小说")
        try store.organizeBooks([b.id]) { $0.pinned = true; $0.groupID = group.id; $0.state = .finished }
        XCTAssertEqual(YueduShelfQuery.books(store.books, sort: .title).first?.id, b.id)
        XCTAssertEqual(YueduShelfQuery.books(store.books, state: .finished, groupID: group.id).map(\.id), [b.id])
        XCTAssertEqual(YueduShelfQuery.books(store.books, ungrouped: true).map(\.id), [c.id])
        store.updateProgress(bookID: a.id, chapterIndex: 0, scrollFraction: 0.2)
        XCTAssertEqual(YueduShelfQuery.books(store.books).count, 3)
    }

    func testReadingTransitionsWantedButPreservesFinishedState() throws {
        let a = store.add(book())
        try store.organizeBooks([a.id]) { $0.state = .wanted }
        store.updateProgress(bookID: a.id, chapterIndex: 0, scrollFraction: 0.2)
        XCTAssertEqual(store.books.first?.readingState, .reading)
        try store.organizeBooks([a.id]) { $0.state = .finished }
        store.updateProgress(bookID: a.id, chapterIndex: 0, scrollFraction: 0.5)
        XCTAssertEqual(store.books.first?.readingState, .finished)
    }

    func testBackupMapsGroupsByNameAndPreservesExistingOrganization() throws {
        let a = store.add(book("新书"))
        let group = try store.saveShelfGroup(name: "小说")
        try store.organizeBooks([a.id]) { $0.groupID = group.id; $0.pinned = true; $0.state = .finished }
        let backup = try YueduLibraryBackup.decode(JSONEncoder().encode(YueduLibraryBackup(library: store.snapshot, sourceURLs: [:])))
        let destination = LibraryStore(directory: directory.appendingPathComponent("destination"))
        let existingGroup = try destination.saveShelfGroup(name: "小说")
        _ = try backup.merge(into: destination, sources: [])
        XCTAssertEqual(destination.shelfGroups.count, 1)
        XCTAssertEqual(destination.books[0].shelfInfo.groupID, existingGroup.id)
        XCTAssertTrue(destination.books[0].shelfInfo.pinned)
        try destination.organizeBooks([destination.books[0].id]) { $0.state = .reading; $0.pinned = false }
        _ = try backup.merge(into: destination, sources: [])
        XCTAssertEqual(destination.books.count, 1)
        XCTAssertEqual(destination.books[0].readingState, .reading)
        XCTAssertFalse(destination.books[0].shelfInfo.pinned)
    }

    func testBackupRejectsDanglingGroupAndRemapsGroupIDCollisions() throws {
        var a = book()
        let id = UUID()
        a.shelf = YueduBookShelfInfo(groupID: id)
        var snapshot = store.snapshot
        snapshot.books = [a]
        XCTAssertThrowsError(try YueduLibraryBackup.decode(JSONEncoder().encode(YueduLibraryBackup(library: snapshot, sourceURLs: [:]))))
        snapshot.shelfGroups = [YueduShelfGroup(id: id, name: "备份分组")]
        let backup = try YueduLibraryBackup.decode(JSONEncoder().encode(YueduLibraryBackup(library: snapshot, sourceURLs: [:])))
        var current = store.snapshot
        current.shelfGroups = [YueduShelfGroup(id: id, name: "本机分组")]
        try store.commit(current)
        _ = try backup.merge(into: store, sources: [])
        XCTAssertEqual(store.shelfGroups.count, 2)
        XCTAssertNotEqual(store.books[0].shelfInfo.groupID, id)
    }
}
