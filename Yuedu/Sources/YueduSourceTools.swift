import Foundation
import CryptoKit

struct YueduSourceCheck: Codable, Equatable {
    enum Outcome: String, Codable { case passed, empty, failed }
    enum Mode: String, CaseIterable, Codable {
        case search, reading
        var title: String { self == .search ? "仅检查搜索" : "搜索、目录与首章" }
    }
    let sourceID: UUID
    let signature: String
    let date: Date
    let keyword: String
    let mode: Mode
    let outcome: Outcome
    let stage: String
    let detail: String
    let duration: TimeInterval

    var title: String {
        switch outcome {
        case .passed: return "检测通过"
        case .empty: return "无搜索结果"
        case .failed: return "检测失败"
        }
    }

    @MainActor static func signature(_ source: BookSource) -> String {
        // A probe always uses an enabled snapshot. Disabling a failed source must
        // retain its diagnostic so the user can still find and repair it.
        var tested = source
        tested.enabled = true
        let data = (try? SourceStore.encode(tested)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum YueduSourceFilter: String, CaseIterable {
    case all, enabled, disabled, discovery, failed, unchecked
    var title: String {
        switch self {
        case .all: return "全部状态"
        case .enabled: return "已启用"
        case .disabled: return "已停用"
        case .discovery: return "支持发现"
        case .failed: return "检测失败"
        case .unchecked: return "尚未检测"
        }
    }
}

enum YueduSourceSort: String, CaseIterable {
    case imported, name, speed
    var title: String {
        switch self {
        case .imported: return "导入顺序"
        case .name: return "名称排序"
        case .speed: return "检测耗时"
        }
    }
}

@MainActor
final class YueduSourceChecker {
    static let shared = YueduSourceChecker(store: .shared)
    typealias Probe = (BookSource, String, YueduSourceCheck.Mode) async throws -> (YueduSourceCheck.Outcome, String, String)
    private let store: SourceStore
    private let fileURL: URL
    private let probe: Probe
    private var records: [UUID: YueduSourceCheck] = [:]
    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var message = "选择书源后检测。检测不会改变书源启停状态或加入书架。"

    init(store: SourceStore, directory: URL? = nil, probe: Probe? = nil) {
        self.store = store
        self.probe = probe ?? Self.probe
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu")
        fileURL = base.appendingPathComponent("source-checks.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let saved = try JSONDecoder().decode([YueduSourceCheck].self, from: Data(contentsOf: fileURL))
                for record in saved { records[record.sourceID] = record }
            }
        } catch { message = "检测记录读取失败：\(error.localizedDescription)" }
    }

    func result(for source: BookSource) -> YueduSourceCheck? {
        guard let record = records[source.id], record.signature == YueduSourceCheck.signature(source) else { return nil }
        return record
    }

    func filtered(query: String, group: String?, filter: YueduSourceFilter, sort: YueduSourceSort) -> [BookSource] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = store.sources.filter { source in
            guard text.isEmpty || "\(source.bookSourceName) \(source.bookSourceUrl) \(source.bookSourceGroup)".localizedCaseInsensitiveContains(text),
                  group == nil || (group == "" ? source.discoveryGroups.isEmpty : source.discoveryGroups.contains(group!)) else { return false }
            switch filter {
            case .all: return true
            case .enabled: return source.enabled
            case .disabled: return !source.enabled
            case .discovery: return source.rawFields["exploreUrl"]?.isEmpty == false
            case .failed: return result(for: source)?.outcome == .failed
            case .unchecked: return result(for: source) == nil
            }
        }
        guard sort != .imported else { return selected }
        return selected.sorted { a, b in
            if sort == .speed {
                let left = result(for: a).flatMap { $0.outcome == .passed ? $0.duration : nil } ?? .greatestFiniteMagnitude
                let right = result(for: b).flatMap { $0.outcome == .passed ? $0.duration : nil } ?? .greatestFiniteMagnitude
                if left != right { return left < right }
            }
            let order = a.bookSourceName.localizedStandardCompare(b.bookSourceName)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }

    func start(ids: Set<UUID>, keyword: String, mode: YueduSourceCheck.Mode) throws {
        guard !isRunning else { throw SourceError.invalid("已有检测正在进行，请等待或先停止。") }
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 80 else { throw SourceError.invalid("请输入 1–80 个字的测试书名或关键词。") }
        let sources = store.sources.filter { ids.contains($0.id) }
        guard !sources.isEmpty else { throw SourceError.invalid("请先选择要检测的书源。") }
        isRunning = true
        message = "准备检测 \(sources.count) 个书源"
        notify()
        task = Task { [weak self] in
            guard let self else { return }
            var finished = 0
            var failures = 0
            var empty = 0
            var stale = 0
            var storageError: String?
            for (index, source) in sources.enumerated() {
                guard !Task.isCancelled else { break }
                guard self.store.source(id: source.id) == source else { stale += 1; continue }
                self.message = "检测 \(index + 1)/\(sources.count) · \(source.bookSourceName)"
                self.notify()
                let began = Date()
                let outcome: YueduSourceCheck.Outcome
                let stage: String
                let detail: String
                do {
                    try source.validate()
                    (outcome, stage, detail) = try await self.probe(source, keyword, mode)
                } catch {
                    if Task.isCancelled || error is CancellationError { break }
                    outcome = .failed
                    stage = "配置或请求"
                    detail = error.localizedDescription
                }
                guard !Task.isCancelled else { break }
                guard self.store.source(id: source.id) == source else { stale += 1; continue }
                let record = YueduSourceCheck(sourceID: source.id, signature: YueduSourceCheck.signature(source),
                    date: Date(), keyword: keyword, mode: mode, outcome: outcome, stage: stage,
                    detail: String(detail.prefix(1500)), duration: Date().timeIntervalSince(began))
                do {
                    var updated = self.records.filter { self.store.source(id: $0.key) != nil }
                    updated[source.id] = record
                    try SourceStore.encode(Array(updated.values)).write(to: self.fileURL, options: .atomic)
                    self.records = updated
                } catch { storageError = error.localizedDescription; break }
                finished += 1
                if outcome == .failed { failures += 1 }
                if outcome == .empty { empty += 1 }
                self.notify()
            }
            self.isRunning = false
            self.task = nil
            self.message = storageError.map { "检测记录保存失败：\($0)" }
                ?? "\(Task.isCancelled ? "已停止" : "检测完成") · \(finished) 个已检测 · \(failures) 个失败 · \(empty) 个无结果"
                    + (stale > 0 ? " · \(stale) 个配置变动已跳过" : "")
            self.notify()
        }
    }

    func cancel() { task?.cancel() }

    private func notify() {
        NotificationCenter.default.post(name: .yueduSourceChecksChanged, object: self)
    }

    private static func probe(_ input: BookSource, keyword: String, mode: YueduSourceCheck.Mode) async throws -> (YueduSourceCheck.Outcome, String, String) {
        // Test a snapshot, including disabled sources, without enabling it in storage.
        var source = input
        source.enabled = true
        let engine = SourceEngine.shared
        var stage = "搜索"
        do {
            let matches = try await engine.search(source: source, query: keyword, timeout: 20)
            try Task.checkCancellation()
            guard let first = matches.first else { return (.empty, stage, "该关键词没有结果，可换常见书名再试；不代表书源失效。") }
            if mode == .search { return (.passed, stage, "返回 \(matches.count) 本书；尚未检测目录和正文。") }
            stage = "目录"
            let book = try await engine.loadBook(first, source: source, timeout: 20)
            try Task.checkCancellation()
            guard let chapter = book.chapters.first else { return (.failed, stage, "未解析到目录。") }
            stage = "首章正文"
            let text = try await engine.loadChapter(chapter, source: source, book: book, timeout: 20)
            try Task.checkCancellation()
            return (.passed, stage, "《\(book.title)》 · \(book.chapters.count) 章 · 首章 \(text.count) 字。")
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return (.failed, stage, error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let yueduSourceChecksChanged = Notification.Name("yueduSourceChecksChanged")
}
