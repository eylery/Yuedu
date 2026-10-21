import Foundation

@MainActor
final class LibraryStore {
    static let shared = LibraryStore()
    private(set) var books: [Book] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var readingSeconds: Double = 0
    private(set) var readingDates: [String] = []
    private(set) var shelfGroups: [YueduShelfGroup] = []
    private(set) var persistenceError: String?
    private let fileURL: URL
    private var cacheRevisions: [UUID: Int] = [:]

    struct Snapshot: Codable {
        var books: [Book]
        var bookmarks: [Bookmark]
        var readingSeconds: Double
        var readingDates: [String]
        var shelfGroups: [YueduShelfGroup]? = nil
    }

    init(directory: URL? = nil, seed: Bool = false) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu", isDirectory: true)
        fileURL = base.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
                books = snapshot.books
                bookmarks = snapshot.bookmarks
                readingSeconds = snapshot.readingSeconds
                readingDates = snapshot.readingDates
                shelfGroups = snapshot.shelfGroups ?? []
            } else if seed {
                books = SampleLibrary.books
                persist(notify: false)
            }
        } catch {
            persistenceError = "书架读取失败，原文件已保留：\(error.localizedDescription)"
        }
    }

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    @discardableResult
    func add(_ book: Book) -> Book {
        if let existing = books.first(where: { candidate in
            if let url = book.bookURL { return candidate.bookURL == url && candidate.sourceID == book.sourceID }
            return candidate.title == book.title && candidate.author == book.author && candidate.sourceName == book.sourceName
        }) { return existing }
        books.insert(book, at: 0)
        persist()
        return book
    }

    func remove(id: UUID) {
        books.removeAll { $0.id == id }
        bookmarks.removeAll { $0.bookID == id }
        persist()
    }

    func updateProgress(bookID: UUID, chapterIndex: Int, scrollFraction: Double) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), !books[index].chapters.isEmpty else { return }
        books[index].progress = ReadingProgress(chapterIndex: min(max(0, chapterIndex), books[index].chapters.count - 1), scrollFraction: min(1, max(0, scrollFraction)))
        books[index].lastReadAt = Date()
        books[index].consumeReadUpdates()
        if books[index].shelf?.state == .wanted {
            books[index].shelf?.state = .reading
        }
        persist()
    }

    func cacheRevision(for bookID: UUID) -> Int { cacheRevisions[bookID, default: 0] }

    @discardableResult
    func cacheChapterContent(bookID: UUID, chapterID: UUID, text: String, revision: Int) throws -> Bool {
        guard cacheRevision(for: bookID) == revision,
              let index = books.firstIndex(where: { $0.id == bookID }),
              let chapter = books[index].chapters.firstIndex(where: { $0.id == chapterID }) else { return false }
        var updated = snapshot
        updated.books[index].chapters[chapter].content = text
        try commit(updated)
        return true
    }

    @discardableResult
    func refreshCatalog(bookID: UUID, fetched: Book) throws -> Int {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            throw SourceError.invalid("这本书已从书架移除。")
        }
        let oldIDs = Set(books[index].chapters.map(\.id))
        var (updatedBook, updatedBookmarks) = try YueduCatalog.refreshed(
            books[index], with: fetched, bookmarks: bookmarks
        )
        let addedIDs = Set(updatedBook.chapters.map(\.id)).subtracting(oldIDs)
        var info = updatedBook.following ?? YueduFollowingInfo()
        info.checkedAt = Date()
        info.error = nil
        if !addedIDs.isEmpty { info.updatedAt = info.checkedAt }
        info.unreadChapterIDs.formIntersection(updatedBook.chapters.map(\.id))
        info.unreadChapterIDs.formUnion(addedIDs)
        updatedBook.following = info
        updatedBook.consumeReadUpdates()
        var updated = snapshot
        updated.books[index] = updatedBook
        updated.bookmarks = updatedBookmarks
        try commit(updated)
        NotificationCenter.default.post(name: .yueduCatalogChanged, object: bookID)
        return addedIDs.count
    }

    var snapshot: Snapshot {
        Snapshot(books: books, bookmarks: bookmarks, readingSeconds: readingSeconds,
                 readingDates: readingDates, shelfGroups: shelfGroups)
    }

    /// Publish state only after the atomic disk write succeeds.
    func commit(_ snapshot: Snapshot, invalidatingCacheFor ids: Set<UUID> = []) throws {
        guard persistenceError == nil else { throw SourceError.invalid(persistenceError!) }
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        books = snapshot.books
        bookmarks = snapshot.bookmarks
        readingSeconds = snapshot.readingSeconds
        readingDates = snapshot.readingDates
        shelfGroups = snapshot.shelfGroups ?? []
        for id in ids { cacheRevisions[id, default: 0] += 1 }
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    func addBookmark(bookID: UUID, chapterIndex: Int, scrollFraction: Double, title: String) {
        guard !bookmarks.contains(where: { $0.bookID == bookID && $0.chapterIndex == chapterIndex && abs($0.scrollFraction - scrollFraction) < 0.01 }) else { return }
        bookmarks.insert(Bookmark(bookID: bookID, chapterIndex: chapterIndex, scrollFraction: scrollFraction, title: title), at: 0)
        persist()
    }

    func removeBookmark(id: UUID) { bookmarks.removeAll { $0.id == id }; persist() }

    func recordReading(seconds: Double) {
        guard seconds > 0 else { return }
        readingSeconds += seconds
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        if !readingDates.contains(day) { readingDates.append(day) }
        persist()
    }

    private func persist(notify: Bool = true) {
        // Never overwrite an unreadable library. The user can recover its original data.
        guard persistenceError == nil else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch { persistenceError = "书架保存失败：\(error.localizedDescription)" }
        if notify { NotificationCenter.default.post(name: .libraryChanged, object: nil) }
    }
}
