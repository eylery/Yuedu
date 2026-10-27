import Foundation

extension BookSource {
    var supportsDiscovery: Bool {
        isTextSource && rawFields["exploreUrl"]?.isEmpty == false
    }

    var isDiscoveryEnabled: Bool {
        get { rawFields["enabledExplore"]?.boolValue != false }
        set { rawFields["enabledExplore"] = .bool(newValue) }
    }

    var hasDiscovery: Bool {
        enabled && supportsDiscovery && isDiscoveryEnabled
    }

    var discoveryGroups: [String] {
        bookSourceGroup.components(separatedBy: CharacterSet(charactersIn: ",;，；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Rules run only for sources the user expands or explicitly refreshes.
/// At most two sources execute at once; collapse, edits and removal cancel stale work.
@MainActor
final class YueduDiscoveryModel {
    enum State: Equatable {
        case waiting
        case loading
        case loaded([SourceCategory])
        case failed(String)
    }

    typealias Loader = (BookSource) async throws -> [SourceCategory]
    private(set) var sources: [BookSource] = []
    private(set) var expanded = Set<UUID>()
    private(set) var states: [UUID: State] = [:]
    var onChange: (() -> Void)?
    private let loader: Loader
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var queue: [UUID] = []

    init(loader: @escaping Loader = { try await SourceEngine.shared.categories(source: $0) }) {
        self.loader = loader
    }

    deinit { tasks.values.forEach { $0.cancel() } }

    var groups: [String] {
        Array(Set(sources.flatMap(\.discoveryGroups))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func filtered(query: String, group: String?) -> [BookSource] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources.filter { source in
            (group == nil || source.discoveryGroups.contains(group!))
                && (term.isEmpty || "\(source.bookSourceName) \(source.bookSourceGroup)".localizedCaseInsensitiveContains(term))
        }
    }

    func updateSources(_ all: [BookSource]) {
        let updated = all.enumerated().filter { $0.element.hasDiscovery }.sorted {
            let left = Int($0.element.rawFields["customOrder"]?.scalarString ?? "") ?? 0
            let right = Int($1.element.rawFields["customOrder"]?.scalarString ?? "") ?? 0
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
            cancel(id)
            states[id] = nil
            if new[id] == nil { expanded.remove(id) }
        }
        sources = updated
        for source in sources where expanded.contains(source.id) && states[source.id] == nil {
            enqueue(source.id)
        }
        drain()
        onChange?()
    }

    func toggle(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        if expanded.contains(id) {
            expanded.remove(id)
            cancel(id)
        } else {
            expanded.insert(id)
            if states[id] == nil { enqueue(id) }
        }
        drain()
        onChange?()
    }

    func retry(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        expanded.insert(id)
        cancel(id)
        states[id] = nil
        enqueue(id)
        drain()
        onChange?()
    }

    func refreshExpanded() {
        for id in expanded {
            cancel(id)
            states[id] = nil
            enqueue(id)
        }
        // A future expansion should not reuse categories from before this refresh.
        for id in Array(states.keys) where !expanded.contains(id) { states[id] = nil }
        drain()
        onChange?()
    }

    func collapseAll() {
        for id in expanded { cancel(id) }
        expanded.removeAll()
        onChange?()
    }

    func suspend() {
        for id in Array(tasks.keys) { cancel(id) }
        for id in queue { states[id] = nil }
        queue.removeAll()
    }

    private func cancel(_ id: UUID) {
        tokens[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0 == id }
        if states[id] == .loading || states[id] == .waiting { states[id] = nil }
    }

    private func enqueue(_ id: UUID) {
        guard !queue.contains(id), tasks[id] == nil else { return }
        states[id] = .waiting
        queue.append(id)
    }

    private func drain() {
        while tasks.count < 2, !queue.isEmpty {
            let id = queue.removeFirst()
            guard expanded.contains(id), let source = sources.first(where: { $0.id == id }) else { continue }
            let token = UUID()
            tokens[id] = token
            states[id] = .loading
            let loader = loader
            tasks[id] = Task { [weak self] in
                do {
                    let categories = try await loader(source)
                    try Task.checkCancellation()
                    guard let self, self.tokens[id] == token else { return }
                    var seen = Set<SourceCategory>()
                    let unique = categories.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
                    self.finish(id, token: token, state: .loaded(unique))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.finish(id, token: token, state: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func finish(_ id: UUID, token: UUID, state: State) {
        guard tokens[id] == token else { return }
        tasks[id] = nil
        tokens[id] = nil
        states[id] = state
        drain()
        onChange?()
    }
}
