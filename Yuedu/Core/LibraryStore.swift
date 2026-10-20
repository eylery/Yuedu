import Foundation

@MainActor
final class LibraryStore {
    static let shared = LibraryStore()
    private(set) var books: [Book] = []
    private(set) var bookmarks: [Bookmark] = []
    private(set) var readingSeconds: Double = 0
    private(set) var readingDates: [String] = []
    private(set) var persistenceError: String?
    private let fileURL: URL

    struct Snapshot: Codable {
        var books: [Book]
        var bookmarks: [Bookmark]
        var readingSeconds: Double
        var readingDates: [String]
    }

    init(directory: URL? = nil, seed: Bool = true) {
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
        persist()
    }

    func updateChapterContent(bookID: UUID, chapterID: UUID, text: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), let chapter = books[index].chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        books[index].chapters[chapter].content = text
        persist()
    }

    @discardableResult
    func refreshCatalog(bookID: UUID, fetched: Book) throws -> Int {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else {
            throw SourceError.invalid("这本书已从书架移除。")
        }
        let oldIDs = Set(books[index].chapters.map(\.id))
        let (updatedBook, updatedBookmarks) = try YueduCatalog.refreshed(
            books[index], with: fetched, bookmarks: bookmarks
        )
        var updated = snapshot
        updated.books[index] = updatedBook
        updated.bookmarks = updatedBookmarks
        try commit(updated)
        return updatedBook.chapters.filter { !oldIDs.contains($0.id) }.count
    }

    var snapshot: Snapshot {
        Snapshot(books: books, bookmarks: bookmarks, readingSeconds: readingSeconds, readingDates: readingDates)
    }

    /// Publish state only after the atomic disk write succeeds.
    func commit(_ snapshot: Snapshot) throws {
        guard persistenceError == nil else { throw SourceError.invalid(persistenceError!) }
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        books = snapshot.books
        bookmarks = snapshot.bookmarks
        readingSeconds = snapshot.readingSeconds
        readingDates = snapshot.readingDates
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
            let snapshot = Snapshot(books: books, bookmarks: bookmarks, readingSeconds: readingSeconds, readingDates: readingDates)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch { persistenceError = "书架保存失败：\(error.localizedDescription)" }
        if notify { NotificationCenter.default.post(name: .libraryChanged, object: nil) }
    }
}
