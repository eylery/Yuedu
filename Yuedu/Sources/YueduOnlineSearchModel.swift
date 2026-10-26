import Foundation

enum YueduSearchMatch: String, CaseIterable {
    case all = "综合匹配"
    case title = "书名包含"
    case author = "作者包含"
    case exactTitle = "书名完全匹配"
}

enum YueduSearchSort: String, CaseIterable {
    case relevance = "相关度优先"
    case title = "按书名排序"
    case author = "按作者排序"
    case source = "按书源顺序"
}

struct YueduSearchRow {
    let versions: [SourceSearchResult]
    var book: SourceSearchResult { versions[0] }
    var title: String { YueduSearchIdentity.title(book.title) }
    var author: String { YueduSearchIdentity.author(book.author) }
    var sourceCount: Int { Set(versions.map(\.sourceID)).count }
}

@MainActor
final class YueduSearchHistory {
    static let key = "search.history"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var queries: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let key = YueduCatalog.normalized(query)
        let others = queries.filter { YueduCatalog.normalized($0) != key }
        defaults.set(Array(([query] + others).prefix(20)), forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Each source owns its next page. Failures never advance that cursor, and
/// empty or repeated pages stop sources that do not implement pagination.
@MainActor
final class YueduOnlineSearchModel {
    struct SourceState {
        let source: BookSource
        var nextPage = 1
        var exhausted = false
        var error: String?
    }

    static let maximumConcurrentSearches = 4
    static let searchTimeout: TimeInterval = 12
    static let retryTimeout: TimeInterval = 30
    typealias Loader = (BookSource, String, Int) async throws -> [SourceSearchResult]
    typealias TimedLoader = (BookSource, String, Int, TimeInterval) async throws -> [SourceSearchResult]
    var onChange: (() -> Void)?
    private(set) var query = ""
    private(set) var results: [SourceSearchResult] = []
    private(set) var states: [SourceState] = []
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var wasCancelled = false
    private(set) var sourcesChanged = false
    private let loader: TimedLoader
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var queue: [UUID] = []
    private var requestTimeout = searchTimeout
    private var performance: [UUID: (source: BookSource, duration: TimeInterval, succeeded: Bool)] = [:]

    init(loader: Loader? = nil) {
        self.loader = { source, query, page, timeout in
            if let loader { return try await loader(source, query, page) }
            return try await SourceEngine.shared.search(source: source, query: query, page: page, timeout: timeout)
        }
    }

    init(timedLoader: @escaping TimedLoader) {
        loader = timedLoader
    }

    deinit { tasks.values.forEach { $0.cancel() } }

    static func eligible(_ sources: [BookSource], excluding: UUID? = nil) -> [BookSource] {
        sources.filter { $0.enabled && $0.isTextSource && $0.id != excluding && !$0.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isSearching: Bool { !tasks.isEmpty || !queue.isEmpty }
    var failures: [SourceState] { states.filter { $0.error != nil } }
    var canLoadMore: Bool { states.contains { !$0.exhausted && $0.error == nil } }

    func reset() {
        stop()
        query = ""
        results = []
        states = []
        completed = 0
        total = 0
        wasCancelled = false
        sourcesChanged = false
        onChange?()
    }

    func search(_ query: String, sources: [BookSource]) {
        stop()
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        var seen = Set<UUID>()
        states = Self.eligible(sources).filter { seen.insert($0.id).inserted }.map { SourceState(source: $0) }
        sourcesChanged = false
        run(states.map { $0.source.id })
    }

    func loadMore() {
        guard !isSearching else { return }
        run(states.filter { !$0.exhausted && $0.error == nil }.map { $0.source.id })
    }

    func retryFailures() {
        guard !isSearching else { return }
        run(failures.map { $0.source.id }, timeout: Self.retryTimeout)
    }

    func cancel() {
        guard isSearching else { return }
        stop()
        wasCancelled = true
        onChange?()
    }

    /// Discard results and late callbacks from edited, disabled or removed
    /// sources. Newly enabled sources participate in the next explicit search.
    func updateSources(_ sources: [BookSource]) {
        let available = Dictionary(uniqueKeysWithValues: Self.eligible(sources).map { ($0.id, $0) })
        let invalid = Set(states.filter { available[$0.source.id] != $0.source }.map { $0.source.id })
        guard !invalid.isEmpty else { return }
        for id in invalid {
            tokens[id] = nil
            tasks.removeValue(forKey: id)?.cancel()
        }
        queue.removeAll { invalid.contains($0) }
        states.removeAll { invalid.contains($0.source.id) }
        results.removeAll { invalid.contains($0.sourceID) }
        sourcesChanged = true
        drain()
        onChange?()
    }

    func rows(match: YueduSearchMatch, sort: YueduSearchSort, merge: Bool, requiredTitle: String? = nil) -> [YueduSearchRow] {
        let key = YueduSearchIdentity.titleKey(query)
        let authorQuery = YueduSearchIdentity.authorKey(query) ?? key
        let requiredTitleKey = requiredTitle.map(YueduSearchIdentity.titleKey)
        let order = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($0.element.source.id, $0.offset) })
        // Normalize each record once; sorting may compare the same book many times.
        let identities = Dictionary(uniqueKeysWithValues: results.map { result in
            (result.id, (title: YueduSearchIdentity.titleKey(result.title),
                         author: YueduSearchIdentity.authorKey(result.author) ?? ""))
        })
        func rank(_ result: SourceSearchResult) -> Int {
            let (title, author) = identities[result.id]!
            if title == key { return 0 }
            if !author.isEmpty, author == authorQuery { return 1 }
            if title.contains(key) { return 2 }
            if !authorQuery.isEmpty, author.contains(authorQuery) { return 3 }
            return 4
        }
        let filtered = results.filter { result in
            let (title, author) = identities[result.id]!
            if let requiredTitleKey, title != requiredTitleKey { return false }
            switch match {
            case .all: return true
            case .title: return title.contains(key)
            case .author: return !authorQuery.isEmpty && author.contains(authorQuery)
            case .exactTitle: return title == key
            }
        }.sorted { left, right in
            if sort == .relevance, rank(left) != rank(right) { return rank(left) < rank(right) }
            if sort == .source, order[left.sourceID] != order[right.sourceID] {
                return (order[left.sourceID] ?? 0) < (order[right.sourceID] ?? 0)
            }
            if sort == .author, left.author != right.author {
                return left.author.localizedStandardCompare(right.author) == .orderedAscending
            }
            if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
            if left.author != right.author { return left.author.localizedStandardCompare(right.author) == .orderedAscending }
            if order[left.sourceID] != order[right.sourceID] { return (order[left.sourceID] ?? 0) < (order[right.sourceID] ?? 0) }
            return left.bookURL < right.bookURL
        }
        var rows: [YueduSearchRow] = []
        var positions: [[String]: Int] = [:]
        for result in filtered {
            let (title, author) = identities[result.id]!
            let canMerge = merge && !title.isEmpty && !author.isEmpty
            let identity = canMerge ? [title, author] : [result.id]
            if let index = positions[identity] {
                rows[index] = YueduSearchRow(versions: rows[index].versions + [result])
            } else {
                positions[identity] = rows.count
                rows.append(YueduSearchRow(versions: [result]))
            }
        }
        return rows
    }

    private func stop() {
        tokens.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        queue.removeAll()
    }

    private func run(_ ids: [UUID], timeout: TimeInterval? = nil) {
        wasCancelled = false
        completed = 0
        total = ids.count
        requestTimeout = timeout ?? Self.searchTimeout
        // Prefer sources that responded successfully during this search session.
        // Keep display/source sort order independent of request scheduling.
        let sources = Dictionary(uniqueKeysWithValues: states.map { ($0.source.id, $0.source) })
        func priority(_ id: UUID) -> (Int, TimeInterval) {
            guard let record = performance[id], record.source == sources[id] else { return (1, 0) }
            return record.succeeded ? (0, record.duration) : (2, 0)
        }
        queue = ids.enumerated().sorted { left, right in
            let a = priority(left.element)
            let b = priority(right.element)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return left.offset < right.offset
        }.map(\.element)
        drain()
        onChange?()
    }

    private func drain() {
        while tasks.count < Self.maximumConcurrentSearches, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let state = states.first(where: { $0.source.id == id }) else { continue }
            let token = UUID()
            tokens[id] = token
            let loader = loader
            let query = query
            let timeout = requestTimeout
            let started = Date()
            tasks[id] = Task { [weak self] in
                do {
                    let incoming = try await loader(state.source, query, state.nextPage, timeout)
                    try Task.checkCancellation()
                    self?.finish(id, token: token, incoming: incoming, error: nil, duration: Date().timeIntervalSince(started))
                } catch {
                    self?.finish(id, token: token, incoming: [], error: error.localizedDescription, duration: Date().timeIntervalSince(started))
                }
            }
        }
    }

    private func finish(_ id: UUID, token: UUID, incoming: [SourceSearchResult], error: String?, duration: TimeInterval) {
        guard tokens[id] == token, let index = states.firstIndex(where: { $0.source.id == id }) else { return }
        tokens[id] = nil
        tasks[id] = nil
        completed += 1
        states[index].error = error
        performance[id] = (states[index].source, duration, error == nil)
        if error == nil {
            var seen = Set(results.map(\.id))
            let added = incoming.filter { $0.sourceID == id && seen.insert($0.id).inserted }
            results.append(contentsOf: added)
            states[index].exhausted = added.isEmpty
            states[index].nextPage += 1
        }
        drain()
        onChange?()
    }
}
