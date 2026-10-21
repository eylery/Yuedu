import Foundation

struct YueduLibraryBackup: Codable {
    static let maximumBytes = 200_000_000
    var format = "YueduLibrary"
    var version = 1
    var createdAt = Date()
    var library: LibraryStore.Snapshot
    var sourceURLs: [String: String]

    static func decode(_ data: Data) throws -> YueduLibraryBackup {
        guard data.count <= maximumBytes else {
            throw SourceError.invalid("书架备份超过 200 MB 上限。")
        }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.format == "YueduLibrary", backup.version == 1 else {
            throw SourceError.invalid("这不是支持的阅读书架备份格式。")
        }
        let snapshot = backup.library
        guard snapshot.books.count <= 10_000,
              Set(snapshot.books.map(\.id)).count == snapshot.books.count,
              Set(snapshot.bookmarks.map(\.id)).count == snapshot.bookmarks.count,
              snapshot.readingSeconds.isFinite, snapshot.readingSeconds >= 0 else {
            throw SourceError.invalid("备份内有重复记录或无效的阅读统计。")
        }
        let groups = snapshot.shelfGroups ?? []
        guard groups.count <= 10_000, Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 20 }) else {
            throw SourceError.invalid("备份中包含无效的书架分组。")
        }
        let groupIDs = Set(groups.map(\.id))
        var booksByID: [UUID: Book] = [:]
        for book in snapshot.books {
            guard Set(book.chapters.map(\.id)).count == book.chapters.count,
                  book.progress.scrollFraction.isFinite,
                  (0...1).contains(book.progress.scrollFraction),
                  (book.chapters.isEmpty ? book.progress.chapterIndex == 0 : book.chapters.indices.contains(book.progress.chapterIndex)) else {
                throw SourceError.invalid("《\(book.title)》的目录或进度无效。")
            }
            if let groupID = book.shelf?.groupID, !groupIDs.contains(groupID) {
                throw SourceError.invalid("《\(book.title)》引用了不存在的书架分组。")
            }
            booksByID[book.id] = book
        }
        for bookmark in snapshot.bookmarks {
            guard let book = booksByID[bookmark.bookID],
                  book.chapters.indices.contains(bookmark.chapterIndex),
                  bookmark.scrollFraction.isFinite,
                  (0...1).contains(bookmark.scrollFraction) else {
                throw SourceError.invalid("备份中包含无效书签。")
            }
        }
        return backup
    }

    @MainActor
    func merge(into store: LibraryStore, sources: [BookSource]) throws -> (books: Int, bookmarks: Int) {
        var updated = store.snapshot
        var mapping: [UUID: UUID] = [:]
        var incomingBooks: [UUID: Book] = [:]
        var groups = updated.shelfGroups ?? []
        var groupMapping: [UUID: UUID] = [:]
        for var group in library.shelfGroups ?? [] {
            let originalID = group.id
            if let existing = groups.first(where: { $0.name.localizedCaseInsensitiveCompare(group.name) == .orderedSame }) {
                groupMapping[originalID] = existing.id
            } else {
                if groups.contains(where: { $0.id == group.id }) { group.id = UUID() }
                groupMapping[originalID] = group.id
                groups.append(group)
            }
        }
        updated.shelfGroups = groups
        let oldBookCount = updated.books.count
        let oldBookmarkCount = updated.bookmarks.count
        for var incoming in library.books {
            let originalID = incoming.id
            if let groupID = incoming.shelf?.groupID {
                incoming.shelf?.groupID = groupMapping[groupID]
            }
            if let sourceID = incoming.sourceID, let url = sourceURLs[sourceID.uuidString] {
                if let source = sources.first(where: { $0.bookSourceUrl == url }) {
                    incoming.sourceID = source.id
                    incoming.sourceName = source.bookSourceName
                } else if sources.contains(where: { $0.id == sourceID }) {
                    throw SourceError.invalid("备份书源与设备上的书源标识冲突。请先导入备份对应的书源配置，再恢复书架。")
                }
            }
            incomingBooks[originalID] = incoming
            // A UUID collision must not merge unrelated books.
            let existing = updated.books.first { candidate in
                if let url = incoming.bookURL {
                    return candidate.bookURL == url && candidate.sourceID == incoming.sourceID
                }
                return candidate.title == incoming.title && candidate.author == incoming.author
                    && candidate.sourceName == incoming.sourceName && candidate.sourceID == nil
            }
            if let existing {
                mapping[originalID] = existing.id
            } else {
                if updated.books.contains(where: { $0.id == incoming.id }) { incoming.id = UUID() }
                mapping[originalID] = incoming.id
                updated.books.append(incoming)
            }
        }
        // Reconnect imported editions even when one of them already existed on this shelf.
        let editionGroups = Dictionary(grouping: library.books.filter { $0.editionGroupID != nil }) {
            $0.editionGroupID!
        }
        for (incomingGroup, members) in editionGroups {
            let ids = Set(members.compactMap { mapping[$0.id] })
            let linked = updated.books.filter { ids.contains($0.id) }
            let groups = Set(linked.compactMap(\.editionGroupID))
            let group = linked.first?.editionGroupID ?? incomingGroup
            for index in updated.books.indices {
                if ids.contains(updated.books[index].id) ||
                    updated.books[index].editionGroupID.map({ groups.contains($0) }) == true {
                    updated.books[index].editionGroupID = group
                }
            }
        }
        for var bookmark in library.bookmarks {
            guard let mappedID = mapping[bookmark.bookID],
                  let incoming = incomingBooks[bookmark.bookID],
                  let destination = updated.books.first(where: { $0.id == mappedID }),
                  let chapterIndex = YueduCatalog.matchingIndex(
                    incoming.chapters[bookmark.chapterIndex], in: destination.chapters, sameSource: true
                  ) else { continue }
            bookmark.bookID = mappedID
            bookmark.chapterIndex = chapterIndex
            let duplicate = updated.bookmarks.contains {
                $0.bookID == mappedID && $0.chapterIndex == chapterIndex
                    && abs($0.scrollFraction - bookmark.scrollFraction) < 0.01
            }
            guard !duplicate else { continue }
            if updated.bookmarks.contains(where: { $0.id == bookmark.id }) { bookmark.id = UUID() }
            updated.bookmarks.append(bookmark)
        }
        updated.readingDates = Array(Set(updated.readingDates + library.readingDates)).sorted()
        // Merging the same backup twice must not double the reading time.
        updated.readingSeconds = max(updated.readingSeconds, library.readingSeconds)
        try store.commit(updated)
        return (updated.books.count - oldBookCount, updated.bookmarks.count - oldBookmarkCount)
    }
}
