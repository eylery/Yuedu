import Foundation

/// Cross-source matching deliberately ignores neither subtitles nor volume prefixes.
/// Equal chapter numbers alone are only a suggestion for manual selection.
enum YueduSourceSwitch {
    struct Match: Equatable {
        let index: Int
        let explanation: String
    }

    static func match(_ chapter: BookChapter, in chapters: [BookChapter]) -> Match? {
        guard !YueduCatalog.normalized(chapter.title).isEmpty else { return nil }
        if let key = chapterKey(chapter.title), key.subtitle.isEmpty { return nil }
        let exact = chapters.indices.filter {
            YueduCatalog.normalized(chapters[$0].title) == YueduCatalog.normalized(chapter.title)
        }
        if !exact.isEmpty {
            return exact.count == 1 ? Match(index: exact[0], explanation: "章节名一致") : nil
        }
        guard let key = chapterKey(chapter.title), !key.subtitle.isEmpty else { return nil }
        let matches = chapters.indices.filter {
            guard let other = chapterKey(chapters[$0].title) else { return false }
            return key.number == other.number && key.subtitle == other.subtitle
        }
        return matches.count == 1 ? Match(index: matches[0], explanation: "章号与标题一致（已统一数字和标点）") : nil
    }

    static func suggestedIndex(_ chapter: BookChapter, in chapters: [BookChapter]) -> Int? {
        guard let number = chapterKey(chapter.title)?.number else { return nil }
        return chapters.firstIndex { chapterKey($0.title)?.number == number }
    }

    static func authorsAgree(_ first: String, _ second: String) -> Bool {
        let a = YueduCatalog.normalized(first)
        let b = YueduCatalog.normalized(second)
        return !["", "佚名", "未知", "未知作者", "暂无"].contains(a) && a == b
    }

    static func metadataAgrees(_ original: Book, _ candidate: Book) -> Bool {
        YueduCatalog.normalized(original.title) == YueduCatalog.normalized(candidate.title)
            && authorsAgree(original.author, candidate.author)
    }

    private static let chapterPattern = try! NSRegularExpression(
        pattern: "^第([0-9零〇一二两三四五六七八九十百千万]+)[章节回]"
    )

    private struct ChapterKey: Hashable {
        let number: Int
        let subtitle: String
    }

    private static func chapterKey(_ title: String) -> ChapterKey? {
        let text = YueduCatalog.normalized(title)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = chapterPattern.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let fullRange = Range(match.range, in: text),
              let number = chineseNumber(String(text[numberRange])) else { return nil }
        // Only boundary punctuation is cosmetic. Internal punctuation and (上/下) remain significant.
        let subtitle = String(text[fullRange.upperBound...]).trimmingCharacters(in: .punctuationCharacters)
        return ChapterKey(number: number, subtitle: subtitle)
    }

    private static func chineseNumber(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2,
                                      "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]
        guard text.count <= 16 else { return nil }
        if text.allSatisfy({ digits[$0] != nil }) {
            return Int(text.compactMap { digits[$0].map(String.init) }.joined())
        }
        var total = 0
        var section = 0
        var digit = 0
        for character in text {
            if let value = digits[character] { digit = value }
            else if let unit = units[character] {
                if unit == 10000 {
                    total += (section + digit) * unit
                    section = 0
                } else {
                    section += max(1, digit) * unit
                }
                digit = 0
            } else { return nil }
        }
        return total + section + digit
    }

    static func bookmarkMapping(from original: Book, to target: Book) -> [Int: Int] {
        var exact: [String: [Int]] = [:]
        var canonical: [ChapterKey: [Int]] = [:]
        for (index, chapter) in target.chapters.enumerated() {
            let title = YueduCatalog.normalized(chapter.title)
            if !title.isEmpty, chapterKey(chapter.title)?.subtitle.isEmpty != true {
                exact[title, default: []].append(index)
            }
            if let key = chapterKey(chapter.title), !key.subtitle.isEmpty {
                canonical[key, default: []].append(index)
            }
        }
        var result: [Int: Int] = [:]
        var counts: [Int: Int] = [:]
        for (index, chapter) in original.chapters.enumerated() {
            let matches = exact[YueduCatalog.normalized(chapter.title)]
                ?? chapterKey(chapter.title).flatMap { canonical[$0] } ?? []
            if matches.count == 1 {
                result[index] = matches[0]
                counts[matches[0], default: 0] += 1
            }
        }
        return result.filter { counts[$0.value] == 1 }
    }
}

@MainActor
extension LibraryStore {
    func savedEdition(of candidate: Book) -> Book? {
        guard let sourceID = candidate.sourceID, let url = candidate.bookURL else { return nil }
        return books.first { $0.sourceID == sourceID && $0.bookURL == url }
    }

    func editions(of book: Book) -> [Book] {
        guard let group = book.editionGroupID else { return [] }
        return books.filter { $0.editionGroupID == group && $0.id != book.id }
            .sorted { ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
    }

    /// One disk commit links the editions, copies mappable bookmarks and saves validated raw text.
    /// Original progress, bookmarks and cache remain intact; existing editions retain their settings.
    func switchSource(original: Book, candidate: Book, chapterIndex: Int,
                      fraction: Double, verifiedText: String, copyBookmarks: Bool,
                      candidateWasSaved: Bool = false) throws -> Book {
        guard let live = book(id: original.id), live.chapters == original.chapters,
              live.progress == original.progress,
              live.sourceID == original.sourceID, live.bookURL == original.bookURL else {
            throw SourceError.invalid("原书目录或进度已变化，请返回重新选择换源版本。")
        }
        guard candidate.id != live.id, candidate.sourceID != nil, candidate.bookURL != nil,
              candidate.chapters.indices.contains(chapterIndex), fraction.isFinite,
              (0...1).contains(fraction),
              !verifiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceError.invalid("请先选择章节并成功试读，再确认换源。")
        }
        let existing = savedEdition(of: candidate)
        if candidateWasSaved, existing?.id != candidate.id {
            throw SourceError.invalid("此版本已从书架移除，请返回重新选择。")
        }
        if let existing, existing != candidate {
            throw SourceError.invalid("此版本的书架数据已变化，请返回重新选择，避免覆盖进度或缓存。")
        }
        var target = candidate
        if existing == nil {
            target.id = UUID()
            target.addedAt = Date()
            target.shelf = live.shelf
            target.following = YueduFollowingInfo(enabled: live.isFollowing)
        }
        target.progress = ReadingProgress(chapterIndex: chapterIndex, scrollFraction: fraction)
        target.lastReadAt = Date()
        if target.shelf?.state == .wanted { target.shelf?.state = .reading }
        target.consumeReadUpdates()
        target.chapters[chapterIndex].content = verifiedText
        let group = live.editionGroupID ?? target.editionGroupID ?? UUID()
        let mergingGroup = target.editionGroupID
        target.editionGroupID = group
        var updated = snapshot
        for index in updated.books.indices {
            if updated.books[index].id == live.id ||
                (mergingGroup != nil && updated.books[index].editionGroupID == mergingGroup) {
                updated.books[index].editionGroupID = group
            }
        }
        if let index = updated.books.firstIndex(where: { $0.id == target.id }) {
            updated.books[index] = target
        } else {
            updated.books.insert(target, at: 0)
        }
        if copyBookmarks {
            let mapping = YueduSourceSwitch.bookmarkMapping(from: live, to: target)
            for bookmark in bookmarks where bookmark.bookID == live.id {
                guard let index = mapping[bookmark.chapterIndex],
                      !updated.bookmarks.contains(where: {
                          $0.bookID == target.id && $0.chapterIndex == index &&
                              abs($0.scrollFraction - bookmark.scrollFraction) < 0.01
                      }) else { continue }
                var copy = bookmark
                copy.id = UUID()
                copy.bookID = target.id
                copy.chapterIndex = index
                updated.bookmarks.append(copy)
            }
        }
        try commit(updated)
        return target
    }
}
