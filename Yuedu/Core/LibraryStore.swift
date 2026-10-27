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
    private var hasUnreadableLibrary = false
    private let storage: YueduChapterStorage
    private var cacheRevisions: [UUID: Int] = [:]
    private(set) var pendingPositions: [UUID: YueduReadingCheckpoint.Position] = [:]
    private var pendingReadingSeconds: Double = 0
    private(set) var readingSaveError: String?

    struct Snapshot: Codable {
        var storageVersion: Int? = nil
        var readingGeneration: UUID? = nil
        var books: [Book]
        var bookmarks: [Bookmark]
        var readingSeconds: Double
        var readingDates: [String]
        var shelfGroups: [YueduShelfGroup]? = nil
    }

    init(directory: URL? = nil, seed: Bool = false) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu", isDirectory: true)
        storage = YueduChapterStorage(directory: base)
        do {
            if let snapshot = try storage.load() {
                books = snapshot.books
                bookmarks = snapshot.bookmarks
                readingSeconds = snapshot.readingSeconds
                readingDates = snapshot.readingDates
                shelfGroups = snapshot.shelfGroups ?? []
                persistenceError = storage.migrationError
            } else if seed {
                var initial = snapshot
                initial.books = SampleLibrary.books
                persist(initial, notify: false)
            }
        } catch {
            hasUnreadableLibrary = true
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
        var updated = snapshot
        updated.books.insert(book, at: 0)
        persist(updated)
        return self.book(id: book.id) ?? book
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        var updated = snapshot
        updated.books.removeAll { $0.id == id }
        updated.bookmarks.removeAll { $0.bookID == id }
        return persist(updated)
    }

    @discardableResult
    func updateProgress(bookID: UUID, chapterIndex: Int, scrollFraction: Double) -> Bool {
        guard scrollFraction.isFinite,
              let index = books.firstIndex(where: { $0.id == bookID }),
              !books[index].chapters.isEmpty else { return false }
        let chapter = books[index].chapters[min(max(0, chapterIndex), books[index].chapters.count - 1)]
        let position = YueduReadingCheckpoint.Position(chapterID: chapter.id,
                                                  fraction: min(1, max(0, scrollFraction)), readAt: Date())
        pendingPositions[bookID] = position
        return savePendingPosition(bookID)
    }

    @discardableResult
    private func savePendingPosition(_ bookID: UUID) -> Bool {
        guard let position = pendingPositions[bookID], let index = books.firstIndex(where: { $0.id == bookID }),
              books[index].chapters.contains(where: { $0.id == position.chapterID }) else {
            pendingPositions[bookID] = nil
            return false
        }
        var book = books[index]
        position.apply(to: &book)
        do {
            guard !hasUnreadableLibrary else { throw SourceError.invalid(persistenceError ?? "书架无法读取。") }
            if storage.canSaveReadingState {
                let unchanged = book.progress == books[index].progress
                    && book.shelf == books[index].shelf
                    && book.following == books[index].following
                    && persistenceError == nil
                    && Date().timeIntervalSince(books[index].lastReadAt ?? .distantPast) < 30
                if !unchanged {
                    try storage.saveReading(bookID: bookID, position: position, seconds: readingSeconds, dates: readingDates)
                    books[index] = book
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                }
            } else {
                var updated = snapshot
                updated.books[index] = book
                try commit(updated)
            }
            pendingPositions[bookID] = nil
            if pendingPositions.isEmpty && pendingReadingSeconds == 0 {
                readingSaveError = nil
                persistenceError = nil
            }
            NotificationCenter.default.post(name: .yueduReadingSaveChanged, object: nil)
            return true
        } catch {
            readingSaveError = "阅读进度未保存：\(error.localizedDescription)"
            persistenceError = readingSaveError
            NotificationCenter.default.post(name: .yueduReadingSaveChanged, object: nil)
            return false
        }
    }

    @discardableResult
    func retryReadingSaves() -> Bool {
        var succeeded = true
        for id in Array(pendingPositions.keys) {
            if !savePendingPosition(id) { succeeded = false }
        }
        if pendingReadingSeconds > 0, !saveReadingTime() { succeeded = false }
        return succeeded
    }

    func resumeProgress(for book: Book) -> ReadingProgress {
        var latest = book
        pendingPositions[book.id]?.apply(to: &latest)
        return latest.progress
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

    func exportBackup(sourceURLs: [String: String]) async throws -> Data {
        try await storage.export(YueduLibraryBackup(library: snapshot, sourceURLs: sourceURLs))
    }

    var snapshot: Snapshot {
        Snapshot(books: books, bookmarks: bookmarks, readingSeconds: readingSeconds,
                 readingDates: readingDates, shelfGroups: shelfGroups)
    }

    /// Publish state only after the atomic disk write succeeds.
    func commit(_ snapshot: Snapshot, invalidatingCacheFor ids: Set<UUID> = [], notify: Bool = true) throws {
        guard !hasUnreadableLibrary else {
            throw SourceError.invalid(persistenceError ?? "书架文件无法读取，原文件已保留。")
        }
        let previous = self.snapshot
        let snapshot = try storage.save(snapshot)
        books = snapshot.books
        bookmarks = snapshot.bookmarks
        readingSeconds = snapshot.readingSeconds
        readingDates = snapshot.readingDates
        shelfGroups = snapshot.shelfGroups ?? []
        pendingPositions = pendingPositions.filter { id, position in
            books.contains { $0.id == id && $0.chapters.contains { $0.id == position.chapterID } }
        }
        persistenceError = nil
        for id in ids { cacheRevisions[id, default: 0] += 1 }
        storage.removeRetiredFiles(from: previous, keeping: snapshot)
        if notify { NotificationCenter.default.post(name: .libraryChanged, object: nil) }
    }

    @discardableResult
    func addBookmark(bookID: UUID, chapterIndex: Int, scrollFraction: Double, title: String) -> Bool {
        guard scrollFraction.isFinite, let book = book(id: bookID),
              book.chapters.indices.contains(chapterIndex) else { return false }
        let fraction = min(1, max(0, scrollFraction))
        guard !bookmarks.contains(where: { $0.bookID == bookID && $0.chapterIndex == chapterIndex && abs($0.scrollFraction - fraction) < 0.01 }) else { return true }
        var updated = snapshot
        updated.bookmarks.insert(Bookmark(bookID: bookID, chapterIndex: chapterIndex, scrollFraction: fraction, title: title), at: 0)
        return persist(updated)
    }

    @discardableResult
    func removeBookmark(id: UUID) -> Bool {
        var updated = snapshot
        updated.bookmarks.removeAll { $0.id == id }
        return persist(updated)
    }

    @discardableResult
    func recordReading(seconds: Double) -> Bool {
        guard seconds.isFinite, seconds > 0, (readingSeconds + pendingReadingSeconds + seconds).isFinite else { return false }
        pendingReadingSeconds += seconds
        return saveReadingTime()
    }

    private func saveReadingTime() -> Bool {
        let seconds = readingSeconds + pendingReadingSeconds
        var dates = readingDates
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        if !dates.contains(day) { dates.append(day) }
        do {
            guard !hasUnreadableLibrary else { throw SourceError.invalid(persistenceError ?? "书架无法读取。") }
            if storage.canSaveReadingState {
                try storage.saveReading(seconds: seconds, dates: dates)
                readingSeconds = seconds
                readingDates = dates
            } else {
                var updated = snapshot
                updated.readingSeconds = seconds
                updated.readingDates = dates
                try commit(updated)
            }
            pendingReadingSeconds = 0
            if pendingPositions.isEmpty { readingSaveError = nil; persistenceError = nil }
            NotificationCenter.default.post(name: .yueduReadingSaveChanged, object: nil)
            return true
        } catch {
            readingSaveError = "阅读记录未保存：\(error.localizedDescription)"
            persistenceError = readingSaveError
            NotificationCenter.default.post(name: .yueduReadingSaveChanged, object: nil)
            return false
        }
    }

    @discardableResult
    private func persist(_ updated: Snapshot, notify: Bool = true) -> Bool {
        guard !hasUnreadableLibrary else { return false }
        do {
            try commit(updated, notify: notify)
            return true
        } catch {
            persistenceError = "书架保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
