import Foundation

enum YueduReadingState: String, Codable, CaseIterable {
    case reading, wanted, finished

    var title: String {
        switch self {
        case .reading: return "在读"
        case .wanted: return "想读"
        case .finished: return "已读"
        }
    }
}

struct YueduBookShelfInfo: Codable, Hashable {
    var pinned = false
    var groupID: UUID? = nil
    var state: YueduReadingState? = nil
}

struct YueduShelfGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

enum YueduShelfSort: String, CaseIterable {
    case recent, added, title, progress, updated

    var title: String {
        switch self {
        case .recent: return "最近阅读"
        case .added: return "最近添加"
        case .title: return "书名"
        case .progress: return "阅读进度"
        case .updated: return "最近更新"
        }
    }
}

extension Book {
    var shelfInfo: YueduBookShelfInfo { shelf ?? YueduBookShelfInfo() }
    var readingState: YueduReadingState {
        shelf?.state ?? (lastReadAt == nil ? .wanted : .reading)
    }

    func isVisibleOnShelf(showSamples: Bool) -> Bool {
        showSamples || !isSample || lastReadAt != nil || shelf != nil
    }
}

enum YueduShelfQuery {
    static func books(_ books: [Book], state: YueduReadingState? = nil,
                      groupID: UUID? = nil, ungrouped: Bool = false,
                      sort: YueduShelfSort = .recent, showSamples: Bool = false) -> [Book] {
        books.filter { book in
            book.isVisibleOnShelf(showSamples: showSamples)
                && (state == nil || book.readingState == state)
                && (groupID == nil || book.shelfInfo.groupID == groupID)
                && (!ungrouped || book.shelfInfo.groupID == nil)
        }.sorted { first, second in
            if first.shelfInfo.pinned != second.shelfInfo.pinned {
                return first.shelfInfo.pinned
            }
            switch sort {
            case .recent:
                let a = first.lastReadAt ?? first.addedAt
                let b = second.lastReadAt ?? second.addedAt
                if a != b { return a > b }
            case .added:
                if first.addedAt != second.addedAt { return first.addedAt > second.addedAt }
            case .title:
                let order = first.title.localizedStandardCompare(second.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .progress:
                if first.fractionRead != second.fractionRead { return first.fractionRead > second.fractionRead }
            case .updated:
                let a = first.following?.updatedAt ?? .distantPast
                let b = second.following?.updatedAt ?? .distantPast
                if a != b { return a > b }
            }
            return first.id.uuidString < second.id.uuidString
        }
    }
}

@MainActor
extension LibraryStore {
    /// Apply a batch with one atomic write; a failed save leaves the live shelf intact.
    func organizeBooks(_ ids: Set<UUID>, edit: (inout YueduBookShelfInfo) -> Void) throws {
        var updated = snapshot
        for index in updated.books.indices where ids.contains(updated.books[index].id) {
            var info = updated.books[index].shelfInfo
            edit(&info)
            guard info.groupID == nil || shelfGroups.contains(where: { $0.id == info.groupID }) else {
                throw SourceError.invalid("分组已不存在，请重新选择。")
            }
            updated.books[index].shelf = info
        }
        try commit(updated)
    }

    func removeBooks(_ ids: Set<UUID>) throws {
        var updated = snapshot
        updated.books.removeAll { ids.contains($0.id) }
        updated.bookmarks.removeAll { ids.contains($0.bookID) }
        try commit(updated)
    }

    @discardableResult
    func saveShelfGroup(name: String, id: UUID? = nil) throws -> YueduShelfGroup {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 20 else {
            throw SourceError.invalid("分组名称请输入 1–20 个字。")
        }
        guard !shelfGroups.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
        }) else {
            throw SourceError.invalid("已有同名分组，请换一个名称。")
        }
        var groups = shelfGroups
        let group: YueduShelfGroup
        if let id {
            guard let index = groups.firstIndex(where: { $0.id == id }) else {
                throw SourceError.invalid("分组已不存在。")
            }
            groups[index].name = cleaned
            group = groups[index]
        } else {
            group = YueduShelfGroup(name: cleaned)
            groups.append(group)
        }
        var updated = snapshot
        updated.shelfGroups = groups
        try commit(updated)
        return group
    }

    func deleteShelfGroup(id: UUID) throws {
        var updated = snapshot
        updated.shelfGroups = shelfGroups.filter { $0.id != id }
        for index in updated.books.indices where updated.books[index].shelf?.groupID == id {
            updated.books[index].shelf?.groupID = nil
        }
        try commit(updated)
    }
}
