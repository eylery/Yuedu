import Foundation

@MainActor
final class YueduBookChoices {
    static let key = "search.bookChoices.v1"
    private let defaults: UserDefaults
    private var choices: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choices = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    private func key(for result: SourceSearchResult) -> String {
        YueduSearchIdentity.titleKey(result.title) + "\u{1F}"
            + (YueduSearchIdentity.authorKey(result.author) ?? result.author) + "\u{1F}"
            + result.sourceID.uuidString
    }

    func preferred(in records: [SourceSearchResult]) -> SourceSearchResult? {
        records.first { choices[key(for: $0)] == $0.bookURL }
    }

    func remember(_ result: SourceSearchResult) {
        if choices.count >= 200, choices[key(for: result)] == nil { choices.removeValue(forKey: choices.keys.sorted().first!) }
        choices[key(for: result)] = result.bookURL
        defaults.set(choices, forKey: Self.key)
    }
}
