import Foundation
import CryptoKit

enum SourceImportLimits {
    static let maximumBytes = 50_000_000
    static let maximumSourceCount = 10_000
}

enum SourceError: LocalizedError {
    case invalid(String)
    case unsupported(String)
    case network(String)
    case empty(String)
    case responseTooLarge(limit: Int, actualBytes: Int64?)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .network(let message), .empty(let message): return message
        case .unsupported(let message): return "当前版本不支持：\(message)"
        case .responseTooLarge(let limit, let actualBytes):
            let allowed = Self.formattedSize(Int64(limit))
            let actual = actualBytes.map { "（已检测到 \(Self.formattedSize($0))）" } ?? ""
            return "内容超过 \(allowed) 上限\(actual)，已停止处理。请拆分书源合集，或使用较小的书源文件。"
        }
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        if bytes < 1_000_000 { return "\(bytes) 字节" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// Preserves source metadata and scripts as JSON values. Import never executes them.
indirect enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .integer(let value): return value != 0
        case .string(let value) where value == "true" || value == "1": return true
        case .string(let value) where value == "false" || value == "0": return false
        default: return nil
        }
    }
    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        default: return false
        }
    }
}

struct SourceImportIssue: Identifiable, Sendable {
    enum Kind: String, Sendable { case invalid, unsupported, excluded }
    var id: Int { index }
    let index: Int
    let name: String
    let reason: String
    let kind: Kind
}

struct SourceImportReport: Sendable {
    let importedCount: Int
    let readyCount: Int
    let disabledCount: Int
    let skippedCount: Int
    let issues: [SourceImportIssue]
    var excludedCount: Int = 0
}

struct BookSource: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var bookSourceName: String
    var bookSourceUrl: String
    var bookSourceGroup: String
    var enabled: Bool
    var searchUrl: String
    var ruleSearch: [String: String]
    var ruleBookInfo: [String: String]
    var ruleToc: [String: String]
    var ruleContent: [String: String]
    var rawFields: [String: JSONValue]

    init(id: UUID = UUID(), bookSourceName: String, bookSourceUrl: String, bookSourceGroup: String = "自定义", enabled: Bool = true, searchUrl: String, ruleSearch: [String: String], ruleBookInfo: [String: String] = [:], ruleToc: [String: String], ruleContent: [String: String]) {
        self.id = id
        self.bookSourceName = bookSourceName
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceGroup = bookSourceGroup
        self.enabled = enabled
        self.searchUrl = searchUrl
        self.ruleSearch = ruleSearch
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
        rawFields = [:]
    }

    init(rawFields: [String: JSONValue]) throws {
        self.rawFields = rawFields
        bookSourceName = rawFields["bookSourceName"]?.stringValue ?? ""
        bookSourceUrl = rawFields["bookSourceUrl"]?.stringValue ?? ""
        id = rawFields["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? Self.stableID(for: bookSourceUrl)
        bookSourceGroup = rawFields["bookSourceGroup"]?.stringValue ?? "自定义"
        enabled = rawFields["enabled"]?.boolValue ?? true
        searchUrl = rawFields["searchUrl"]?.stringValue ?? ""
        func rules(_ name: String) -> [String: String] {
            rawFields[name]?.objectValue?.compactMapValues(\.scalarString) ?? [:]
        }
        ruleSearch = rules("ruleSearch")
        ruleBookInfo = rules("ruleBookInfo")
        ruleToc = rules("ruleToc")
        ruleContent = rules("ruleContent")
        try validateStructure()
    }

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let fields = raw.objectValue else { throw SourceError.invalid("书源必须是 JSON 对象。") }
        try self.init(rawFields: fields)
    }

    private var persistentFields: [String: JSONValue] {
        var fields = rawFields
        fields["id"] = .string(id.uuidString)
        fields["bookSourceName"] = .string(bookSourceName)
        fields["bookSourceUrl"] = .string(bookSourceUrl)
        fields["bookSourceGroup"] = .string(bookSourceGroup)
        fields["enabled"] = .bool(enabled)
        // Preserve malformed/unknown raw representations for disabled sources;
        // never discard unsupported scripts, request options or extension fields.
        if fields["searchUrl"]?.stringValue != nil || fields["searchUrl"] == nil || !searchUrl.isEmpty {
            fields["searchUrl"] = .string(searchUrl)
        }
        for (key, rules) in [("ruleSearch", ruleSearch), ("ruleBookInfo", ruleBookInfo), ("ruleToc", ruleToc), ("ruleContent", ruleContent)] {
            if fields[key] != nil && fields[key]?.objectValue == nil && rules.isEmpty { continue }
            var original = fields[key]?.objectValue ?? [:]
            for name in original.keys where original[name]?.scalarString != nil && rules[name] == nil {
                original.removeValue(forKey: name)
            }
            for (name, value) in rules where original[name]?.scalarString != value { original[name] = .string(value) }
            fields[key] = .object(original)
        }
        return fields
    }

    func encode(to encoder: Encoder) throws { try JSONValue.object(persistentFields).encode(to: encoder) }
    static func == (lhs: BookSource, rhs: BookSource) -> Bool { lhs.persistentFields == rhs.persistentFields }
    func hash(into hasher: inout Hasher) { hasher.combine(persistentFields) }

    static func stableID(for baseURL: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], (bytes[6] & 0x0f) | 0x80, bytes[7], (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func validateStructure() throws {
        guard !bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceError.invalid("缺少有效的书源名称 bookSourceName。") }
        guard !bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceError.invalid("缺少有效的书源标识 bookSourceUrl。") }
    }

    var sourceType: Int { Int(rawFields["bookSourceType"]?.scalarString ?? "0") ?? -1 }
    var isTextSource: Bool { sourceType == 0 }
    var isCompatible: Bool { compatibilityIssues.isEmpty }

    /// Import checks structure. Rule execution belongs to the Legado runtime;
    /// JavaScript, request options, login fields and opaque IDs are valid inputs.
    var compatibilityIssues: [String] {
        var issues: [String] = []
        if !isTextSource { issues.append("已排除非文字书源（类型 \(sourceType)）。") }
        for (section, rules) in [("ruleSearch", ruleSearch), ("ruleBookInfo", ruleBookInfo), ("ruleToc", ruleToc), ("ruleContent", ruleContent)] {
            if let raw = rawFields[section], !raw.isEmpty, raw.objectValue == nil {
                issues.append("\(section)：规则应为 JSON 对象。")
            }
            for key in rules.keys {
                if let raw = rawFields[section]?.objectValue?[key], !raw.isEmpty, raw.stringValue == nil {
                    // Unknown extension metadata remains opaque. Only execution
                    // fields are required to have the string shape used by Legado.
                    let executionFields: Set<String> = ["bookList", "name", "author", "bookUrl", "intro", "kind", "tocUrl", "init", "chapterList", "chapterName", "chapterUrl", "nextTocUrl", "content", "nextContentUrl", "replaceRegex", "webJs", "callBackJs"]
                    if executionFields.contains(key) { issues.append("\(section).\(key)：规则必须是字符串。") }
                }
            }
            if let fields = rawFields[section]?.objectValue {
                for key in ["bookList", "name", "author", "bookUrl", "intro", "kind", "tocUrl", "init", "chapterList", "chapterName", "chapterUrl", "nextTocUrl", "content", "nextContentUrl", "replaceRegex", "webJs", "callBackJs"] {
                    if let raw = fields[key], !raw.isEmpty, raw.scalarString == nil { issues.append("\(section).\(key)：规则必须是字符串。") }
                }
            }
        }
        return issues
    }

    func validate() throws {
        try validateStructure()
        if let first = compatibilityIssues.first { throw SourceError.unsupported(first) }
    }

    func validatedHeaders() throws -> [String: String] {
        guard let raw = rawFields["header"], !raw.isEmpty else { return [:] }
        let object: [String: JSONValue]
        if let fields = raw.objectValue { object = fields }
        else if let text = raw.stringValue, let data = text.data(using: .utf8),
                let fields = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue { object = fields }
        else { throw SourceError.unsupported("仅支持静态 JSON 请求头，动态 JavaScript 请求头尚不可用。") }
        var headers: [String: String] = [:]
        for (name, value) in object {
            guard var text = value.stringValue else { throw SourceError.unsupported("请求头的值必须是字符串。") }
            if text == "baseUrl" && ["referer", "origin"].contains(name.lowercased()) { text = bookSourceUrl }
            headers[name] = text
        }
        return try LegadoRule.validatedHeaders(headers)
    }

    static var example: BookSource {
        BookSource(bookSourceName: "本地测试书源", bookSourceUrl: "http://localhost:8080", bookSourceGroup: "示例 · 需自行启动服务", enabled: false, searchUrl: "/search?q={{key}}&page={{page}}", ruleSearch: ["bookList": "$.books[*]", "name": "$.name", "author": "$.author", "bookUrl": "$.url", "intro": "$.intro"], ruleBookInfo: ["tocUrl": "$.tocUrl"], ruleToc: ["chapterList": "$.chapters[*]", "chapterName": "$.title", "chapterUrl": "$.url"], ruleContent: ["content": "$.content"])
    }
}

struct SourceSearchResult: Identifiable, Hashable {
    var id: String { sourceID.uuidString + bookURL }
    let sourceID: UUID
    let sourceName: String
    let title: String
    let author: String
    let summary: String
    let bookURL: String
    var context: [String: JSONValue]? = nil
}

enum SourceURL {
    static func resolve(_ value: String, relativeTo base: String?) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value, relativeTo: base.flatMap(URL.init(string:)))?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw SourceError.invalid("网址必须是有效的 HTTP 或 HTTPS 地址：\(value)")
        }
        return url
    }

    static func search(_ template: String, key: String, page: Int, base: String) throws -> URL {
        let lowered = template.lowercased()
        if template.range(of: #",\s*\{"#, options: .regularExpression) != nil || lowered.contains("<js>") || lowered.contains("@js:") {
            throw SourceError.unsupported("搜索请求中的脚本或 POST / 自定义请求选项")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let result = template.replacingOccurrences(of: "{{key}}", with: encoded).replacingOccurrences(of: "{{page}}", with: String(page))
        guard !result.contains("{{"), !result.contains("}}") else { throw SourceError.unsupported("仅支持 {{key}} 与 {{page}} 网址变量") }
        return try resolve(result, relativeTo: base)
    }
}

enum SourceRule {
    static func validate(_ rule: String) throws { try LegadoRule.validate(rule) }
}

/// Deliberately small, deterministic JSONPath subset: $.field, ['field'], [index], [*].
enum SimpleJSONPath {
    enum Token: Equatable { case key(String), index(Int), wildcard }

    static func tokens(_ path: String) throws -> [Token] {
        guard path.first == "$" else { throw SourceError.invalid("JSONPath 必须以 $ 开头：\(path)") }
        var tokens: [Token] = []
        var cursor = path.index(after: path.startIndex)
        func invalid() -> SourceError { .unsupported("JSONPath \(path)；仅支持字段、数字索引及 [*]") }
        while cursor < path.endIndex {
            let character = path[cursor]
            if character == "." {
                cursor = path.index(after: cursor)
                let start = cursor
                while cursor < path.endIndex, path[cursor] != ".", path[cursor] != "[" { cursor = path.index(after: cursor) }
                let key = String(path[start..<cursor])
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw invalid() }
                tokens.append(.key(key))
            } else if character == "[" {
                let start = path.index(after: cursor)
                guard let end = path[start...].firstIndex(of: "]") else { throw invalid() }
                let value = String(path[start..<end])
                if value == "*" { tokens.append(.wildcard) }
                else if let number = Int(value), number >= 0 { tokens.append(.index(number)) }
                else if value.count >= 2, (value.first == "'" && value.last == "'" || value.first == "\"" && value.last == "\"") {
                    let key = String(value.dropFirst().dropLast())
                    guard !key.contains("\\"), !key.isEmpty else { throw invalid() }
                    tokens.append(.key(key))
                } else { throw invalid() }
                cursor = path.index(after: end)
            } else { throw invalid() }
        }
        return tokens
    }

    static func values(_ path: String, in root: Any) throws -> [Any] {
        var current: [Any] = [root]
        for token in try tokens(path) {
            current = current.flatMap { value -> [Any] in
                switch token {
                case .key(let key): return (value as? [String: Any])?[key].map { [$0] } ?? []
                case .index(let index):
                    guard let array = value as? [Any], array.indices.contains(index) else { return [] }; return [array[index]]
                case .wildcard: return value as? [Any] ?? []
                }
            }
        }
        return current
    }

    static func text(_ path: String, in root: Any) throws -> String {
        try values(path, in: root).compactMap { value -> String? in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Notification.Name {
    static let sourcesChanged = Notification.Name("sourcesChanged")
}
