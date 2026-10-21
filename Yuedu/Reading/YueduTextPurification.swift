import Foundation

struct YueduPurificationRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case literal, regex, chapterTitle
        var title: String {
            switch self {
            case .literal: return "普通替换"
            case .regex: return "正则替换"
            case .chapterTitle: return "重复章名"
            }
        }
    }

    enum Scope: String, Codable, CaseIterable {
        case all, book, source
        var title: String {
            switch self {
            case .all: return "所有书籍"
            case .book: return "仅本书"
            case .source: return "同一书源"
            }
        }
    }

    var id = UUID()
    var name: String
    var enabled = true
    var kind: Kind = .literal
    var pattern = ""
    var replacement = ""
    var scope: Scope = .all
    var targetID: UUID?
    var targetName: String?

    func applies(bookID: UUID?, sourceID: UUID?) -> Bool {
        guard enabled else { return false }
        switch scope {
        case .all: return true
        case .book: return targetID != nil && targetID == bookID
        case .source: return targetID != nil && targetID == sourceID
        }
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              pattern.utf16.count <= 2_000, replacement.utf16.count <= 4_000,
              scope == .all || targetID != nil else {
            throw SourceError.invalid("请填写规则名称（最多 60 字）和有效范围。匹配内容最多 2,000 字，替换内容最多 4,000 字。")
        }
        if kind != .chapterTitle && pattern.isEmpty { throw SourceError.invalid("匹配内容不能为空。留空替换内容表示删除匹配文字。") }
        if kind == .regex {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw SourceError.invalid("正则表达式无效：\(error.localizedDescription)") }
        }
    }

    static var presets: [YueduPurificationRule] {
        [YueduPurificationRule(name: "清理零宽空格", kind: .regex, pattern: "[\u{200B}\u{FEFF}]"),
         YueduPurificationRule(name: "合并多余空行", kind: .regex, pattern: #"\n[\t 　]*(?:\r?\n[\t 　]*){2,}"#, replacement: "\n\n"),
         YueduPurificationRule(name: "清理重复章名", kind: .chapterTitle)]
    }
}

struct YueduPurificationSettings: Codable, Equatable {
    var enabled = true
    var originalBookIDs = Set<UUID>()
    var rules: [YueduPurificationRule] = []
}

struct YueduPurificationResult {
    var text: String
    var hits: [UUID: Int] = [:]
    var warnings: [String] = []
    var restoredOriginal = false
}

/// A display transform only. Never writes cleaned text into the chapter cache.
enum YueduTextPurifier {
    static let maximumLength = 8_000_000

    static func apply(_ original: String, chapterTitle: String, bookID: UUID?, sourceID: UUID?,
                      settings: YueduPurificationSettings, budget: TimeInterval = 0.5) throws -> YueduPurificationResult {
        try Task.checkCancellation()
        var result = YueduPurificationResult(text: original)
        guard settings.enabled, bookID.map({ !settings.originalBookIDs.contains($0) }) ?? true else { return result }
        guard original.utf16.count <= maximumLength else {
            result.warnings = ["本章过长，已保留原文。"]
            return result
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.001, budget)
        for rule in settings.rules where rule.applies(bookID: bookID, sourceID: sourceID) {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime > deadline {
                result.warnings.append("净化耗时超过限制，剩余规则未执行。")
                break
            }
            do {
                try rule.validate()
                let pattern: String
                let template: String
                switch rule.kind {
                case .literal:
                    pattern = NSRegularExpression.escapedPattern(for: rule.pattern)
                    template = NSRegularExpression.escapedTemplate(for: rule.replacement)
                case .regex:
                    pattern = rule.pattern
                    template = rule.replacement
                case .chapterTitle:
                    let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    pattern = #"\A[\t 　\r\n\uFEFF]*"# + NSRegularExpression.escapedPattern(for: title) + #"[\t 　]*(?:\r?\n|\z)"#
                    template = ""
                }
                let expression = try NSRegularExpression(pattern: pattern)
                let text = result.text
                let input = text as NSString
                var output = ""
                var cursor = 0
                var count = 0
                var outputLength = 0
                var interrupted = false
                expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: input.length)) { match, _, stop in
                    if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
                        interrupted = true
                        stop.pointee = true
                        return
                    }
                    guard let match else { return }
                    let replacement = expression.replacementString(for: match, in: text, offset: 0, template: template)
                    let prefixLength = match.range.location - cursor
                    outputLength += prefixLength + replacement.utf16.count
                    if outputLength > maximumLength || count >= 100_000 {
                        interrupted = true
                        stop.pointee = true
                        return
                    }
                    output += input.substring(with: NSRange(location: cursor, length: prefixLength))
                    output += replacement
                    cursor = NSMaxRange(match.range)
                    count += 1
                }
                try Task.checkCancellation()
                guard !interrupted, outputLength + input.length - cursor <= maximumLength else {
                    result.warnings.append("「\(rule.name)」超出处理限制，已跳过整条规则。")
                    continue
                }
                if count > 0 {
                    output += input.substring(from: cursor)
                    result.text = output
                    result.hits[rule.id] = count
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.warnings.append("「\(rule.name)」未应用：\(error.localizedDescription)") }
        }
        if !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.text = original
            result.restoredOriginal = true
            result.warnings.append("净化后正文为空，已自动显示原文。请检查规则。")
        }
        return result
    }

    static func process(_ text: String, chapterTitle: String, bookID: UUID?, sourceID: UUID?,
                        settings: YueduPurificationSettings) async throws -> YueduPurificationResult {
        let task = Task.detached(priority: .userInitiated) {
            try apply(text, chapterTitle: chapterTitle, bookID: bookID, sourceID: sourceID, settings: settings)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
}

extension Notification.Name {
    static let yueduPurificationChanged = Notification.Name("yueduPurificationChanged")
}

@MainActor
final class YueduPurificationStore {
    static let shared = YueduPurificationStore()
    private(set) var settings = YueduPurificationSettings()
    private(set) var loadError: String?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu")
        fileURL = base.appendingPathComponent("purification.json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let saved = try JSONDecoder().decode(YueduPurificationSettings.self, from: Data(contentsOf: fileURL))
                try Self.validate(saved)
                settings = saved
            }
        } catch { loadError = "净化配置读取失败：\(error.localizedDescription)" }
    }

    private static func validate(_ settings: YueduPurificationSettings) throws {
        guard settings.rules.count <= 100, Set(settings.rules.map(\.id)).count == settings.rules.count else {
            throw SourceError.invalid("最多保留 100 条净化规则，规则标识不能重复。")
        }
        for rule in settings.rules { try rule.validate() }
    }

    func update(_ edit: (inout YueduPurificationSettings) throws -> Void) throws {
        guard loadError == nil else { throw SourceError.invalid(loadError!) }
        var updated = settings
        try edit(&updated)
        try Self.validate(updated)
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        settings = updated
        NotificationCenter.default.post(name: .yueduPurificationChanged, object: nil)
    }

    func save(_ rule: YueduPurificationRule) throws {
        try update { settings in
            if let index = settings.rules.firstIndex(where: { $0.id == rule.id }) { settings.rules[index] = rule }
            else { settings.rules.append(rule) }
        }
    }

    struct Export: Codable {
        var format = "YueduPurification"
        var version = 1
        var rules: [YueduPurificationRule]
    }

    func exportData() throws -> Data {
        if let loadError { throw SourceError.invalid(loadError) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(rules: settings.rules))
    }

    func importData(_ data: Data) throws -> Int {
        guard data.count <= 1_000_000 else { throw SourceError.invalid("净化规则文件不能超过 1 MB。") }
        let incoming = try JSONDecoder().decode(Export.self, from: data)
        guard incoming.format == "YueduPurification", incoming.version == 1 else { throw SourceError.invalid("请选择本应用导出的净化规则文件。") }
        try Self.validate(YueduPurificationSettings(rules: incoming.rules))
        var added = 0
        try update { settings in
            for var rule in incoming.rules {
                // Imported rules require inspection before activation; never
                // overwrite an existing rule or silently broaden its scope.
                guard !settings.rules.contains(where: {
                    $0.name == rule.name && $0.kind == rule.kind && $0.pattern == rule.pattern
                        && $0.replacement == rule.replacement && $0.scope == rule.scope && $0.targetID == rule.targetID
                }) else { continue }
                rule.id = UUID()
                rule.enabled = false
                settings.rules.append(rule)
                added += 1
            }
        }
        return added
    }
}
