import Foundation

/// Match only unambiguous identities. Chapter numbers alone are not identities.
enum YueduCatalog {
    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    static func matchingIndex(_ chapter: BookChapter, in chapters: [BookChapter], sameSource: Bool) -> Int? {
        if sameSource, let index = chapters.firstIndex(where: { $0.id == chapter.id }) {
            return index
        }
        if sameSource, let url = chapter.url, !url.isEmpty {
            let matches = chapters.indices.filter { chapters[$0].url == url }
            if matches.count == 1 { return matches[0] }
        }
        let title = normalized(chapter.title)
        guard !title.isEmpty else { return nil }
        let matches = chapters.indices.filter { normalized(chapters[$0].title) == title }
        return matches.count == 1 ? matches[0] : nil
    }

    static func refreshed(_ old: Book, with fetched: Book, bookmarks: [Bookmark]) throws -> (Book, [Bookmark]) {
        guard old.sourceID == fetched.sourceID, old.bookURL == fetched.bookURL,
              !fetched.chapters.isEmpty else {
            throw SourceError.invalid("新目录与原书不一致，已保留原书数据。")
        }
        var updated = old
        updated.summary = fetched.summary
        updated.category = fetched.category
        updated.sourceContext = fetched.sourceContext
        updated.chapters = fetched.chapters
        var mapping: [Int: Int] = [:]
        var used = Set<Int>()
        for (oldIndex, chapter) in old.chapters.enumerated() {
            guard let newIndex = matchingIndex(chapter, in: fetched.chapters, sameSource: true),
                  used.insert(newIndex).inserted else { continue }
            mapping[oldIndex] = newIndex
            updated.chapters[newIndex].id = chapter.id
            updated.chapters[newIndex].body = chapter.body
        }
        if old.lastReadAt != nil {
            guard let newIndex = mapping[old.progress.chapterIndex] else {
                throw SourceError.invalid("新目录中找不到正在阅读的章节。为保护进度，原目录和缓存已保留；可通过换源选择续读章节。")
            }
            updated.progress.chapterIndex = newIndex
        } else {
            updated.progress = ReadingProgress()
        }
        var remapped = bookmarks
        for index in remapped.indices where remapped[index].bookID == old.id {
            guard let chapterIndex = mapping[remapped[index].chapterIndex] else {
                throw SourceError.invalid("新目录中有书签对应的章节缺失。原目录和书签已保留，请先检查目录变化。")
            }
            remapped[index].chapterIndex = chapterIndex
        }
        return (updated, remapped)
    }
}

extension Book {
    var cachedChapterCount: Int {
        chapters.filter { $0.hasCachedContent }.count
    }

    var searchResult: SourceSearchResult? {
        guard let sourceID, let bookURL else { return nil }
        return SourceSearchResult(
            sourceID: sourceID, sourceName: sourceName, title: title,
            author: author, summary: summary, bookURL: bookURL, context: sourceContext
        )
    }
}
