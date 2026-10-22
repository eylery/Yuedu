import Foundation

struct BookChapter: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body: YueduChapterBody
    var content: String {
        get { (try? body.read()) ?? "" }
        set { body = YueduChapterBody(newValue) }
    }
    var hasCachedContent: Bool { body.hasText }
    var cachedByteCount: Int { body.byteCount }
    var url: String? = nil
    var sourceContext: [String: JSONValue]? = nil

    init(id: UUID = UUID(), title: String, content: String, url: String? = nil,
         sourceContext: [String: JSONValue]? = nil) {
        self.id = id
        self.title = title
        self.body = YueduChapterBody(content)
        self.url = url
        self.sourceContext = sourceContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, bodyReference, url, sourceContext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        sourceContext = try values.decodeIfPresent([String: JSONValue].self, forKey: .sourceContext)
        if let reference = try values.decodeIfPresent(YueduChapterReference.self, forKey: .bodyReference) {
            guard let directory = decoder.userInfo[.yueduChapterDirectory] as? URL,
                  reference.bytes > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .bodyReference, in: values,
                                                       debugDescription: "Invalid chapter storage reference")
            }
            body = YueduChapterBody(reference: reference, directory: directory)
        } else {
            body = YueduChapterBody(try values.decode(String.self, forKey: .content))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(url, forKey: .url)
        try values.encodeIfPresent(sourceContext, forKey: .sourceContext)
        if encoder.userInfo[.yueduMetadataOnly] as? Bool == true, let reference = body.reference {
            try values.encode(reference, forKey: .bodyReference)
        } else {
            // Portable backups always contain text, never device-local file paths.
            try values.encode(body.read(), forKey: .content)
        }
    }

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
