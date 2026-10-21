import Foundation

struct YueduFollowingInfo: Codable, Hashable {
    var enabled: Bool? = nil
    var checkedAt: Date? = nil
    var updatedAt: Date? = nil
    var unreadChapterIDs: Set<UUID> = []
    var error: String? = nil
}

extension Book {
    var canFollow: Bool { sourceID != nil && bookURL != nil && !isSample }
    var isFollowing: Bool { canFollow && (following?.enabled ?? (readingState != .finished)) }
    var unreadUpdateCount: Int {
        chapters.filter { following?.unreadChapterIDs.contains($0.id) == true }.count
    }
    var latestChapterTitle: String { chapters.last?.title ?? "暂无章节" }

    mutating func consumeReadUpdates() {
        guard lastReadAt != nil, following != nil else { return }
        let consumed = chapters.enumerated().filter {
            $0.offset < progress.chapterIndex || ($0.offset == progress.chapterIndex && progress.scrollFraction >= 0.98)
        }.map { $0.element.id }
        following?.unreadChapterIDs.subtract(consumed)
    }
}

@MainActor
extension LibraryStore {
    func setFollowing(_ ids: Set<UUID>, enabled: Bool) throws {
        var updated = snapshot
        for index in updated.books.indices where ids.contains(updated.books[index].id) && updated.books[index].canFollow {
            var info = updated.books[index].following ?? YueduFollowingInfo()
            info.enabled = enabled
            updated.books[index].following = info
        }
        try commit(updated)
    }

    func clearUpdateMarks(_ ids: Set<UUID>) throws {
        var updated = snapshot
        for index in updated.books.indices where ids.contains(updated.books[index].id) {
            updated.books[index].following?.unreadChapterIDs.removeAll()
        }
        try commit(updated)
    }

    func recordUpdateFailure(bookID: UUID, message: String) throws {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var updated = snapshot
        var info = updated.books[index].following ?? YueduFollowingInfo()
        info.checkedAt = Date()
        info.error = message
        updated.books[index].following = info
        try commit(updated)
    }
}

extension Notification.Name {
    static let yueduFollowingChanged = Notification.Name("yueduFollowingChanged")
    static let yueduCatalogChanged = Notification.Name("yueduCatalogChanged")
}

/// Foreground-only catalog checks. One book at a time avoids flooding book sources.
@MainActor
final class YueduFollowingManager {
    static let shared = YueduFollowingManager(
        store: .shared,
        loader: { book in
            guard let result = book.searchResult else { throw SourceError.invalid("此书无法在线更新。") }
            return try await SourceEngine.shared.loadBook(result)
        },
        sourceAvailable: { id in SourceStore.shared.source(id: id)?.enabled == true }
    )

    typealias Loader = (Book) async throws -> Book
    private let store: LibraryStore
    private let loader: Loader
    private let sourceAvailable: (UUID) -> Bool
    private var task: Task<Void, Never>?
    private var inFlight = Set<UUID>()
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var message = "下拉或轻点检查，获取最新章节。"

    init(store: LibraryStore, loader: @escaping Loader, sourceAvailable: @escaping (UUID) -> Bool) {
        self.store = store
        self.loader = loader
        self.sourceAvailable = sourceAvailable
    }

    func start(ids: Set<UUID>? = nil, automatic: Bool = false, now: Date = Date()) {
        guard !isRunning else { return }
        let books = store.books.filter {
            $0.isFollowing && (ids == nil || ids!.contains($0.id))
                && (!automatic || now.timeIntervalSince($0.following?.checkedAt ?? .distantPast) >= 30 * 60)
        }
        guard !books.isEmpty else {
            if !automatic {
                message = "没有需要检查的追更书籍。"
                notify()
            }
            return
        }
        isRunning = true
        completed = 0
        total = books.count
        message = "准备检查 \(total) 本书"
        notify()
        task = Task { [weak self] in
            guard let self else { return }
            var added = 0
            var failures = 0
            var checked = 0
            for book in books {
                guard !Task.isCancelled else { break }
                guard self.store.book(id: book.id)?.isFollowing == true else { continue }
                self.message = "正在检查 \(self.completed + 1)/\(self.total) · \(book.title)"
                self.notify()
                do {
                    added += try await self.checkBook(bookID: book.id, requireFollowing: true)
                    checked += 1
                } catch {
                    if Task.isCancelled { break }
                    // Pausing/removing a book during its request is a deliberate skip.
                    if !(error is CancellationError) { failures += 1 }
                }
                self.completed += 1
            }
            self.message = Task.isCancelled
                ? "已停止检查，已完成的更新已保留。"
                : "检查完成 · \(checked) 本成功 · 新增 \(added) 章" + (failures > 0 ? " · \(failures) 本失败，可重试" : "")
            self.isRunning = false
            self.task = nil
            self.notify()
        }
    }

    func cancel() {
        task?.cancel()
        if isRunning {
            message = "正在停止检查…"
            notify()
        }
    }

    @discardableResult
    func checkBook(bookID: UUID, requireFollowing: Bool = false) async throws -> Int {
        guard let original = store.book(id: bookID), original.canFollow else {
            throw SourceError.invalid("书籍已移除或不支持在线更新。")
        }
        guard inFlight.insert(bookID).inserted else {
            throw SourceError.invalid("这本书正在检查更新，请稍后再试。")
        }
        defer { inFlight.remove(bookID) }
        do {
            guard let sourceID = original.sourceID, sourceAvailable(sourceID) else {
                throw SourceError.invalid("书源已停用或移除，请在书源页处理后重试。")
            }
            let fetched = try await loader(original)
            try Task.checkCancellation()
            guard let current = store.book(id: bookID), current.sourceID == original.sourceID,
                  current.bookURL == original.bookURL, sourceAvailable(sourceID),
                  !requireFollowing || current.isFollowing else {
                throw CancellationError()
            }
            return try store.refreshCatalog(bookID: bookID, fetched: fetched)
        } catch {
            if !(error is CancellationError), !Task.isCancelled,
               let current = store.book(id: bookID), current.sourceID == original.sourceID,
               current.bookURL == original.bookURL, !requireFollowing || current.isFollowing {
                try store.recordUpdateFailure(bookID: bookID, message: error.localizedDescription)
            }
            throw error
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .yueduFollowingChanged, object: self)
    }
}
