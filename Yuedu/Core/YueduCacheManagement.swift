import Foundation

enum YueduCacheCleanup {
    case all
    case read
    case chapters(Set<UUID>)
}

struct YueduCacheSummary {
    var chapters = 0
    var bytes = 0

    var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension Book {
    var supportsCacheManagement: Bool { sourceID != nil && bookURL != nil && !isSample }

    var cacheSummary: YueduCacheSummary {
        chapters.reduce(into: YueduCacheSummary()) { result, chapter in
            if chapter.hasCachedContent {
                result.chapters += 1
            }
            result.bytes += chapter.cachedByteCount
        }
    }
}

@MainActor
extension LibraryStore {
    func cacheChapterIDs(bookID: UUID, cleanup: YueduCacheCleanup) -> Set<UUID> {
        guard let book = book(id: bookID), book.supportsCacheManagement else { return [] }
        let protected = Set(bookmarks.filter { $0.bookID == bookID }.map(\.chapterIndex))
        return Set(book.chapters.enumerated().compactMap { index, chapter in
            guard chapter.cachedByteCount > 0 else { return nil }
            switch cleanup {
            case .all: return chapter.id
            case .read:
                return book.lastReadAt != nil && index < book.progress.chapterIndex && !protected.contains(index)
                    ? chapter.id : nil
            case .chapters(let ids): return ids.contains(chapter.id) ? chapter.id : nil
            }
        })
    }

    /// Call through the download manager in production so queued/background work is stopped first.
    @discardableResult
    func clearCachedChapters(bookIDs: Set<UUID>, cleanup: YueduCacheCleanup) throws -> YueduCacheSummary {
        var updated = snapshot
        var removed = YueduCacheSummary()
        for index in updated.books.indices where bookIDs.contains(updated.books[index].id) {
            let ids = cacheChapterIDs(bookID: updated.books[index].id, cleanup: cleanup)
            for chapter in updated.books[index].chapters.indices where ids.contains(updated.books[index].chapters[chapter].id) {
                removed.chapters += 1
                removed.bytes += updated.books[index].chapters[chapter].cachedByteCount
                updated.books[index].chapters[chapter].content = ""
            }
        }
        // Also invalidate in-flight foreground loads when the selected book has no saved body yet.
        let onlineIDs = Set(books.filter { bookIDs.contains($0.id) && $0.supportsCacheManagement }.map(\.id))
        try commit(updated, invalidatingCacheFor: onlineIDs)
        return removed
    }
}
