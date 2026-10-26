import Foundation

/// Search-only presentation keys. Original source metadata and URLs stay intact.
enum YueduSearchIdentity {
    private static let edgeMarks = CharacterSet(charactersIn: ".。·•:：,，、;；")
        .union(.whitespacesAndNewlines)
    private static let unknownAuthors: Set<String> = [
        "", "未知", "未知作者", "佚名", "无名氏", "匿名", "不详", "作者不详", "暂无作者", "暂无", "unknown", "n/a"
    ]

    static func title(_ value: String) -> String {
        var value = clean(value)
        let wrappers: [(Character, Character)] = [("《", "》"), ("〈", "〉"), ("「", "」"), ("『", "』")]
        while wrappers.contains(where: { value.first == $0.0 && value.last == $0.1 }), value.count > 2 {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func author(_ value: String) -> String {
        var value = clean(value).trimmingCharacters(in: edgeMarks)
        value = replacing(value, pattern: #"^作者\s*[:：]\s*"#)
        // Only remove recognized era/country annotations, never arbitrary aliases.
        value = replacing(value, pattern: #"^[\(\[【〔]\s*(?:先秦|春秋|战国|两汉|东汉|西汉|三国|两晋|南北朝|北宋|南宋|民国|秦|汉|晋|隋|唐|宋|元|明|清|美|英|法|德|俄|日|意|加|澳)(?:朝|代|国)?\s*[\)\]】〕]\s*"#)
        value = value.trimmingCharacters(in: edgeMarks)
        // Keep editor/translator/adaptation credits and co-author boundaries.
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
        if !["编著", "原著", "合著", "编撰"].contains(where: { compact.hasSuffix($0) }) {
            let candidate = replacing(value, pattern: #"\s*(?:[\(\[【]\s*(?:著|撰)\s*[\)\]】]|著|撰)$"#)
                .trimmingCharacters(in: edgeMarks)
            if candidate.count >= 2 { value = candidate }
        }
        return value
    }

    static func titleKey(_ value: String) -> String {
        YueduCatalog.normalized(title(value))
    }

    static func authorKey(_ value: String) -> String? {
        let key = YueduCatalog.normalized(author(value))
        return unknownAuthors.contains(key) ? nil : key
    }

    private static func clean(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
            .replacingOccurrences(of: #"[\u200B\u200C\u200D\u2060\uFEFF\u00AD]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ value: String, pattern: String) -> String {
        value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

struct YueduSearchSourceGroup {
    let sourceID: UUID
    let sourceName: String
    var records: [SourceSearchResult]

    static func grouped(_ results: [SourceSearchResult]) -> [YueduSearchSourceGroup] {
        var groups: [YueduSearchSourceGroup] = []
        var positions: [UUID: Int] = [:]
        var seen = Set<String>()
        for result in results where seen.insert(result.id).inserted {
            if let index = positions[result.sourceID] {
                groups[index].records.append(result)
            } else {
                positions[result.sourceID] = groups.count
                groups.append(YueduSearchSourceGroup(
                    sourceID: result.sourceID, sourceName: result.sourceName, records: [result]
                ))
            }
        }
        return groups.map { group in
            var group = group
            group.records.sort { $0.bookURL.localizedStandardCompare($1.bookURL) == .orderedAscending }
            return group
        }
    }
}
