import Foundation

/// Reader, prefetch and foreground downloads share the same in-flight request.
/// Cancelling one consumer never cancels a request still needed by another.
@MainActor
final class YueduChapterRequests {
    typealias Loader = (BookChapter, Book, BookSource) async throws -> String
    private struct Key: Hashable {
        let book: UUID
        let chapter: UUID
        let revision: Int
        let sourceSignature: String
    }
    private struct Entry {
        let token: UUID
        let task: Task<String, Error>
        var consumers: Set<UUID>
    }
    private var entries: [Key: Entry] = [:]
    private let loader: Loader

    init(loader: Loader? = nil) {
        self.loader = loader ?? { chapter, book, source in
            try await SourceEngine.shared.loadChapter(chapter, source: source, book: book)
        }
    }

    func load(_ chapter: BookChapter, book: Book, source: BookSource, revision: Int) async throws -> String {
        try Task.checkCancellation()
        let key = Key(book: book.id, chapter: chapter.id, revision: revision,
                      sourceSignature: YueduSourceCheck.signature(source))
        let consumer = UUID()
        if entries[key] == nil {
            let loader = loader
            entries[key] = Entry(token: UUID(), task: Task { try await loader(chapter, book, source) }, consumers: [])
        }
        entries[key]!.consumers.insert(consumer)
        let entry = entries[key]!
        defer { release(consumer, key: key, token: entry.token) }
        return try await withTaskCancellationHandler {
            let text = try await entry.task.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(consumer, key: key, token: entry.token) }
        }
    }

    private func release(_ consumer: UUID, key: Key, token: UUID) {
        guard var entry = entries[key], entry.token == token else { return }
        entry.consumers.remove(consumer)
        if entry.consumers.isEmpty {
            entries[key] = nil
            entry.task.cancel()
        } else {
            entries[key] = entry
        }
    }
}
