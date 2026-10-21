import Foundation

struct BookChapter: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var content: String
    var url: String? = nil
    var sourceContext: [String: JSONValue]? = nil
}

struct ReadingProgress: Codable, Hashable {
    var chapterIndex = 0
    var scrollFraction = 0.0
}

struct Book: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var summary: String
    var category: String
    var coverColor: String
    var coverSymbol: String
    var chapters: [BookChapter]
    var sourceName: String
    var sourceID: UUID? = nil
    var bookURL: String? = nil
    var sourceContext: [String: JSONValue]? = nil
    var isSample = false
    var addedAt = Date()
    var lastReadAt: Date? = nil
    var progress = ReadingProgress()
    var shelf: YueduBookShelfInfo? = nil
    var following: YueduFollowingInfo? = nil
    var editionGroupID: UUID? = nil

    var fractionRead: Double {
        guard !chapters.isEmpty else { return 0 }
        return min(1, max(0, (Double(progress.chapterIndex) + progress.scrollFraction) / Double(chapters.count)))
    }
    var currentChapterTitle: String {
        guard chapters.indices.contains(progress.chapterIndex) else { return "开始阅读" }
        return chapters[progress.chapterIndex].title
    }
}

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    var bookID: UUID
    var chapterIndex: Int
    var scrollFraction: Double
    var title: String
    var createdAt = Date()
}

extension Notification.Name {
    static let libraryChanged = Notification.Name("libraryChanged")
}
