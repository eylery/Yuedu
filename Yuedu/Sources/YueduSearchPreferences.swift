import Foundation

@MainActor
final class YueduSearchPreferences {
    static let performanceKey = "search.performance.v1"
    static let scopeKey = "search.scope.v1"
    private let defaults: UserDefaults
    private struct Performance: Codable {
        let signature: String
        let date: Date
        let duration: TimeInterval
        let succeeded: Bool
    }
    private var records: [String: Performance]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: Self.performanceKey)
            .flatMap { try? JSONDecoder().decode([String: Performance].self, from: $0) } ?? [:]
        records = records.filter { Date().timeIntervalSince($0.value.date) < 30 * 86_400 }
    }

    var scope: Set<UUID>? {
        get { defaults.stringArray(forKey: Self.scopeKey).map { Set($0.compactMap(UUID.init(uuidString:))) } }
        set {
            if let newValue { defaults.set(newValue.map(\.uuidString), forKey: Self.scopeKey) }
            else { defaults.removeObject(forKey: Self.scopeKey) }
        }
    }

    func priority(for source: BookSource) -> (Int, TimeInterval) {
        guard let record = records[source.id.uuidString],
              record.signature == YueduSourceCheck.signature(source),
              Date().timeIntervalSince(record.date) < 30 * 86_400 else { return (1, 0) }
        return record.succeeded ? (0, record.duration) : (2, 0)
    }

    func record(_ source: BookSource, duration: TimeInterval, succeeded: Bool) {
        records[source.id.uuidString] = Performance(signature: YueduSourceCheck.signature(source),
                                                   date: Date(), duration: max(0, duration), succeeded: succeeded)
        if records.count > 500 {
            records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.date > $1.value.date }.prefix(500).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.performanceKey) }
    }
}
