import Foundation

@MainActor
final class SourceStore {
    static let shared = SourceStore()
    private(set) var sources: [BookSource] = []
    private(set) var persistenceError: String?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu", isDirectory: true)
        fileURL = base.appendingPathComponent("sources.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                sources = try JSONDecoder().decode([BookSource].self, from: Data(contentsOf: fileURL)).filter(\.isTextSource)
            }
        } catch { persistenceError = "书源文件读取失败，原文件已保留：\(error.localizedDescription)" }
    }

    func source(id: UUID) -> BookSource? { sources.first { $0.id == id } }

    nonisolated private static func collectionValues(_ data: Data) throws -> [JSONValue] {
        try Task.checkCancellation()
        guard data.count <= SourceImportLimits.maximumBytes else {
            throw SourceError.responseTooLarge(limit: SourceImportLimits.maximumBytes, actualBytes: Int64(data.count))
        }
        let raw: JSONValue
        do { raw = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw SourceError.invalid("书源不是有效的 JSON：\(error.localizedDescription)") }
        let values: [JSONValue]
        switch raw {
        case .array(let items): values = items
        case .object: values = [raw]
        default: throw SourceError.invalid("请导入一个书源对象或书源对象数组。")
        }
        guard !values.isEmpty, values.count <= SourceImportLimits.maximumSourceCount else {
            throw SourceError.invalid("每次请导入 1 至 \(SourceImportLimits.maximumSourceCount) 个书源，本次检测到 \(values.count) 个。请拆分合集后重试。")
        }
        return values
    }

    /// Strict structural decoding for the single-source editor and synchronous callers.
    /// Execution compatibility never discards a valid configuration.
    nonisolated static func decode(_ data: Data) throws -> [BookSource] {
        try collectionValues(data).compactMap { value in
            try Task.checkCancellation()
            guard let fields = value.objectValue else { throw SourceError.invalid("书源条目必须是 JSON 对象。") }
            var source = try BookSource(rawFields: fields)
            guard source.isTextSource else { return nil }
            if !source.isCompatible { source.enabled = false }
            return source
        }
    }

    private struct ParsedImport: Sendable {
        let sources: [BookSource]
        let report: SourceImportReport
    }

    nonisolated private static func parseCollection(_ data: Data) throws -> ParsedImport {
        let values = try collectionValues(data)
        var sources: [BookSource] = []
        var issues: [SourceImportIssue] = []
        var readyCount = 0
        var disabledCount = 0
        var skippedCount = 0
        var excludedCount = 0
        for (offset, value) in values.enumerated() {
            try Task.checkCancellation()
            let index = offset + 1
            let name = value.objectValue?["bookSourceName"]?.stringValue ?? "第 \(index) 项"
            do {
                guard let fields = value.objectValue else { throw SourceError.invalid("条目不是 JSON 对象。") }
                var source = try BookSource(rawFields: fields)
                guard source.isTextSource else {
                    excludedCount += 1
                    issues.append(SourceImportIssue(index: index, name: source.bookSourceName, reason: "已按类型排除漫画、有声、视频或其他非文字书源。", kind: .excluded))
                    continue
                }
                let reasons = source.compatibilityIssues
                if reasons.isEmpty { readyCount += 1 }
                else {
                    source.enabled = false
                    disabledCount += 1
                    issues.append(SourceImportIssue(index: index, name: source.bookSourceName, reason: reasons.joined(separator: "\n"), kind: .unsupported))
                }
                sources.append(source)
            } catch is CancellationError { throw CancellationError() }
            catch {
                skippedCount += 1
                issues.append(SourceImportIssue(index: index, name: name, reason: error.localizedDescription, kind: .invalid))
            }
        }
        return ParsedImport(sources: sources, report: SourceImportReport(importedCount: sources.count, readyCount: readyCount, disabledCount: disabledCount, skippedCount: skippedCount, issues: issues, excludedCount: excludedCount))
    }

    @discardableResult
    func importData(_ data: Data) throws -> Int {
        try merge(Self.decode(data))
    }

    @discardableResult
    func importDataAsync(_ data: Data) async throws -> SourceImportReport {
        let parsed = try await Self.parseInBackground { try Self.parseCollection(data) }
        try Task.checkCancellation()
        if !parsed.sources.isEmpty { _ = try merge(parsed.sources) }
        return parsed.report
    }

    @discardableResult
    func importFile(_ url: URL) async throws -> SourceImportReport {
        let parsed = try await Self.parseInBackground {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true else { throw SourceError.invalid("请选择书源 JSON 文件。") }
            if let size = attributes.fileSize, size > SourceImportLimits.maximumBytes {
                throw SourceError.responseTooLarge(limit: SourceImportLimits.maximumBytes, actualBytes: Int64(size))
            }
            return try Self.parseCollection(Data(contentsOf: url, options: .mappedIfSafe))
        }
        try Task.checkCancellation()
        if !parsed.sources.isEmpty { _ = try merge(parsed.sources) }
        return parsed.report
    }

    nonisolated private static func parseInBackground<T: Sendable>(_ parse: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: parse)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func merge(_ imported: [BookSource]) throws -> Int {
        var updated = sources
        var indices: [String: Int] = [:]
        for (index, source) in updated.enumerated() where indices[source.bookSourceUrl] == nil {
            indices[source.bookSourceUrl] = index
        }
        var usedIDs = Set(updated.map(\.id))
        for var source in imported {
            if let index = indices[source.bookSourceUrl] {
                source.id = updated[index].id
                updated[index] = source
            } else {
                // Untrusted exports may reuse IDs across unrelated sources.
                while usedIDs.contains(source.id) { source.id = UUID() }
                usedIDs.insert(source.id)
                indices[source.bookSourceUrl] = updated.count
                updated.append(source)
            }
        }
        try commit(updated)
        return imported.count
    }

    func save(_ input: BookSource) throws {
        var source = input
        try source.validateStructure()
        guard source.isTextSource else { throw SourceError.invalid("此应用仅保存文字书源，已排除其他内容类型。") }
        if !source.isCompatible { source.enabled = false }
        var updated = sources
        if let duplicate = updated.first(where: { $0.bookSourceUrl == source.bookSourceUrl && $0.id != source.id }) {
            throw SourceError.invalid("已存在相同网址的书源：\(duplicate.bookSourceName)。请编辑现有书源。")
        }
        if let index = updated.firstIndex(where: { $0.id == source.id }) { updated[index] = source }
        else { updated.append(source) }
        try commit(updated)
    }

    func setEnabled(id: UUID, enabled: Bool) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        if enabled, let reason = sources[index].compatibilityIssues.first {
            throw SourceError.unsupported("该书源暂不能启用：\(reason)")
        }
        var updated = sources
        updated[index].enabled = enabled
        try commit(updated)
    }

    func remove(id: UUID) throws { try commit(sources.filter { $0.id != id }) }

    func exportData() throws -> Data { try Self.encode(sources) }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func commit(_ updated: [BookSource]) throws {
        guard persistenceError == nil else { throw SourceError.invalid(persistenceError!) }
        do {
            try Self.encode(updated).write(to: fileURL, options: .atomic)
            sources = updated
            NotificationCenter.default.post(name: .sourcesChanged, object: nil)
        } catch { throw SourceError.invalid("书源保存失败：\(error.localizedDescription)") }
    }
}
