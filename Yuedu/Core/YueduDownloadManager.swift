import UIKit

extension Notification.Name {
    static let yueduDownloadsChanged = Notification.Name("yueduDownloadsChanged")
}

@MainActor
final class YueduDownloadManager {
    struct Status {
        var message: String
        var isRunning: Bool
        var failures: [String] = []
        var completed = 0
        var total = 0
        var failedCount = 0
    }

    private struct Request: Codable {
        var id = UUID()
        var bookID: UUID
        var sourceID: UUID
        var chapterIDs: [UUID]
        var paused: Bool? = nil
        var failedIDs: [UUID]? = nil
        var failures: [String]? = nil

        var isActive: Bool { paused != true }
    }

    static let shared = YueduDownloadManager()
    private let library: LibraryStore
    private let load: (BookChapter, Book) async throws -> String
    private let usesSourceEngine: Bool
    private let transfers: YueduBackgroundTransfer?
    private let queueFile: URL?
    private var queue: [Request] = []
    private var worker: Task<Void, Never>?
    private var currentID: UUID?
    private var statuses: [UUID: Status] = [:]
    private var observers: [NSObjectProtocol] = []
    private var foreground: Bool
    private(set) var queueError: String?

    init(library: LibraryStore? = nil, observeBackground: Bool = true,
         queueFile: URL? = nil, backgroundTransfers: YueduBackgroundTransfer? = nil,
         load: ((BookChapter, Book) async throws -> String)? = nil) {
        self.library = library ?? .shared
        usesSourceEngine = load == nil
        self.load = load ?? { chapter, book in
            try await SourceEngine.shared.loadChapter(chapter, sourceID: book.sourceID, book: book)
        }
        transfers = backgroundTransfers ?? (load == nil ? .shared : nil)
        self.queueFile = queueFile ?? (library == nil
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Yuedu/download-queue-v1.json") : nil)
        foreground = !observeBackground || UIApplication.shared.applicationState == .active
        if let file = self.queueFile, FileManager.default.fileExists(atPath: file.path) {
            do {
                queue = try JSONDecoder().decode([Request].self, from: Data(contentsOf: file))
                queue.removeAll { self.library.book(id: $0.bookID)?.sourceID != $0.sourceID }
                for request in queue {
                    statuses[request.bookID] = Status(
                        message: request.isActive ? "已恢复缓存任务" : "已暂停 · 可按原范围继续",
                        isRunning: request.isActive, failures: request.failures ?? []
                    )
                }
            } catch {
                // Never overwrite an unreadable queue with a new request.
                queueError = "缓存队列读取失败，原文件已保留：\(error.localizedDescription)"
                for book in self.library.books where book.sourceID != nil {
                    statuses[book.id] = Status(message: queueError!, isRunning: false)
                }
            }
        }
        if observeBackground {
            observe(UIApplication.didEnterBackgroundNotification) { $0.enterBackground() }
            observe(UIApplication.didBecomeActiveNotification) { $0.enterForeground() }
            observe(.libraryChanged) { manager in
                let removed = Set(manager.queue.filter {
                    manager.library.book(id: $0.bookID)?.sourceID != $0.sourceID
                }.map(\.bookID))
                if !removed.isEmpty {
                    do { try manager.cancel(bookIDs: removed) }
                    catch { for id in removed { manager.report(error, bookID: id) } }
                }
            }
            observe(.sourcesChanged) { manager in
                for request in manager.queue where SourceStore.shared.source(id: request.sourceID)?.enabled != true {
                    manager.pause(bookID: request.bookID)
                }
            }
        }
        if let transfers {
            Task { [weak self] in
                await transfers.connect()
                guard let self else { return }
                transfers.retain(books: Set(self.queue.filter(\.isActive).map(\.bookID)))
                for request in self.queue { self.prepare(request) }
                self.runNext()
            }
        } else {
            runNext()
        }
    }

    deinit {
        worker?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observe(_ name: Notification.Name, action: @escaping (YueduDownloadManager) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    func status(for bookID: UUID) -> Status? {
        guard var status = statuses[bookID] else { return nil }
        if let request = queue.first(where: { $0.bookID == bookID }) {
            status.total = request.chapterIDs.count
            let ids = Set(request.chapterIDs)
            status.completed = library.book(id: bookID)?.chapters.filter {
                ids.contains($0.id) && $0.hasCachedContent
            }.count ?? 0
            status.failedCount = request.failedIDs?.count ?? 0
            status.failures = request.failures ?? []
        }
        guard status.isRunning else { return status }
        if let error = transfers?.persistenceError {
            status.message += "\n\(error)"
        }
        let summary = transfers?.summary(bookID: bookID)
        let transferring = summary?.transferring ?? 0
        let ready = summary?.ready ?? 0
        let waiting = summary?.waiting ?? 0
        if !foreground {
            if transferring + ready + waiting > 0 {
                status.message = "后台传输 \(transferring) 章 · 已下载 \(ready) 章待解析 · 待调度 \(waiting) 章\n返回应用后自动解析并保存正文。"
            } else {
                status.message = "等待前台处理 · 队列已保存，返回应用后自动继续"
            }
        } else if ready + transferring > 0 {
            status.message += "\n后台传输 \(transferring) 章 · 已下载 \(ready) 章待解析"
        }
        return status
    }

    var taskBookIDs: Set<UUID> { Set(queue.map(\.bookID)) }

    func canResume(bookID: UUID) -> Bool {
        queue.contains { $0.bookID == bookID && !$0.isActive }
    }

    func failedChapterIDs(bookID: UUID) -> Set<UUID> {
        Set(queue.first { $0.bookID == bookID }?.failedIDs ?? [])
    }

    func start(bookID: UUID, startIndex: Int = 0, limit: Int? = nil) {
        guard let book = library.book(id: bookID) else { return }
        let chapters = book.chapters.dropFirst(min(book.chapters.count, max(0, startIndex)))
            .prefix(max(0, limit ?? book.chapters.count))
        start(bookID: bookID, chapterIDs: Set(chapters.map(\.id)))
    }

    func start(bookID: UUID, chapterIDs: Set<UUID>) {
        guard let book = library.book(id: bookID), let sourceID = book.sourceID,
              !queue.contains(where: { $0.bookID == bookID && $0.isActive }) else { return }
        let ids = book.chapters.filter { chapterIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        let request = Request(bookID: bookID, sourceID: sourceID, chapterIDs: ids)
        var updated = queue.filter { $0.bookID != bookID }
        updated.append(request)
        do { try replaceQueue(updated) }
        catch { report(error, bookID: bookID); return }
        statuses[bookID] = Status(message: "等待缓存", isRunning: true)
        prepare(request)
        notify()
        runNext()
    }

    func resume(bookID: UUID, failuresOnly: Bool = false) {
        guard let request = queue.first(where: { $0.bookID == bookID && !$0.isActive }) else { return }
        start(bookID: bookID, chapterIDs: Set(failuresOnly ? request.failedIDs ?? [] : request.chapterIDs))
    }

    private func prepare(_ request: Request) {
        guard request.isActive, usesSourceEngine, let transfers, let book = library.book(id: request.bookID) else { return }
        let ids = Set(request.chapterIDs)
        let chapters = book.chapters.filter { ids.contains($0.id) }
        do { try transfers.enqueue(SourceEngine.shared.backgroundPlans(book: book, chapters: chapters)) }
        catch {
            statuses[book.id]?.message = "后台队列无法保存，将在前台缓存：\(error.localizedDescription)"
        }
    }

    func pause(bookID: UUID) {
        guard let index = queue.firstIndex(where: { $0.bookID == bookID }) else { return }
        var updated = queue
        updated[index].paused = true
        do { try replaceQueue(updated) }
        catch { report(error, bookID: bookID); return }
        if currentID == bookID { worker?.cancel() }
        transfers?.remove(bookID: bookID)
        statuses[bookID] = Status(message: "已暂停 · 已完成的章节已保存，可继续原范围", isRunning: false)
        notify()
    }

    func pauseAll() {
        for id in queue.filter(\.isActive).map(\.bookID) { pause(bookID: id) }
    }

    func resumeAll() {
        for id in queue.filter({ !$0.isActive }).map(\.bookID) { resume(bookID: id) }
    }

    func cancel(bookIDs: Set<UUID>) throws {
        try replaceQueue(queue.filter { !bookIDs.contains($0.bookID) })
        if let currentID, bookIDs.contains(currentID) { worker?.cancel() }
        for id in bookIDs {
            transfers?.remove(bookID: id)
            statuses[id] = Status(message: "任务已取消 · 已完成的缓存保留", isRunning: false)
        }
        notify()
    }

    @discardableResult
    func clearCache(bookIDs: Set<UUID>, cleanup: YueduCacheCleanup) throws -> YueduCacheSummary {
        let ids = Set(library.books.filter { bookIDs.contains($0.id) && $0.supportsCacheManagement }.map(\.id))
        // Persist cancellation before clearing; a relaunch must not refill intentionally removed bodies.
        try cancel(bookIDs: ids)
        return try library.clearCachedChapters(bookIDs: ids, cleanup: cleanup)
    }

    /// Suspension pauses WebKit evaluation, but preserves both queues and all
    /// native download tasks. This is different from a user choosing Pause.
    func enterBackground() {
        foreground = false
        worker?.cancel()
        notify()
    }

    func enterForeground() {
        foreground = true
        runNext()
        notify()
    }

    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func runNext() {
        guard foreground, worker == nil, let request = queue.first(where: \.isActive) else { return }
        currentID = request.bookID
        worker = Task { [weak self] in
            guard let self else { return }
            let completed = await self.download(request)
            if completed, let index = self.queue.firstIndex(where: { $0.id == request.id && $0.isActive }) {
                var updated = self.queue
                if updated[index].failedIDs?.isEmpty == false {
                    updated[index].paused = true
                } else {
                    updated.remove(at: index)
                }
                do { try self.replaceQueue(updated) }
                catch {
                    // Stop in memory on a disk failure, rather than repeatedly running the same task.
                    self.queue[index].paused = true
                    self.report(error, bookID: request.bookID)
                }
                self.transfers?.remove(bookID: request.bookID)
                self.notify()
            }
            self.worker = nil
            self.currentID = nil
            self.runNext()
        }
    }

    /// False means interrupted, leaving the durable request available to resume.
    private func download(_ request: Request) async -> Bool {
        if usesSourceEngine, SourceStore.shared.source(id: request.sourceID)?.enabled != true {
            suspend(request, message: "书源已停用或移除，请恢复书源后继续")
            return false
        }
        var failures = request.failures ?? []
        var failedIDs = request.failedIDs ?? []
        let revision = library.cacheRevision(for: request.bookID)
        for (offset, id) in request.chapterIDs.enumerated() {
            if Task.isCancelled || !queue.contains(where: { $0.id == request.id && $0.isActive }) { return false }
            guard let book = library.book(id: request.bookID), book.sourceID == request.sourceID,
                  let chapter = book.chapters.first(where: { $0.id == id }) else {
                statuses[request.bookID] = Status(message: "书籍或目录已变化，请重新开始缓存", isRunning: false)
                notify()
                return true
            }
            if chapter.hasCachedContent {
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
                continue
            }
            // Foreground resumption keeps failures for an explicit retry, rather than looping on them.
            if failedIDs.contains(id) { continue }
            statuses[request.bookID] = Status(
                message: "正在缓存 \(offset + 1)/\(request.chapterIDs.count) · \(chapter.title)", isRunning: true
            )
            notify()
            do {
                let text = try await load(chapter, book)
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SourceError.empty("未获取到正文")
                }
                let cachedBytes = library.book(id: book.id)?.chapters.reduce(0) { $0 + $1.cachedByteCount } ?? 0
                guard cachedBytes + text.utf8.count <= 100_000_000 else {
                    suspend(request, message: "已达到单本书 100 MB 上限，可清理后重新缓存。")
                    return false
                }
                guard queue.contains(where: { $0.id == request.id && $0.isActive }),
                      try library.cacheChapterContent(bookID: book.id, chapterID: chapter.id, text: text, revision: revision) else {
                    if queue.contains(where: { $0.id == request.id && $0.isActive }) {
                        suspend(request, message: "缓存或目录已变化，请检查后继续。")
                    }
                    return false
                }
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                if Task.isCancelled { return false }
                if !failedIDs.contains(chapter.id) { failedIDs.append(chapter.id) }
                if failures.count < 30 { failures.append("\(chapter.title)：\(error.localizedDescription.prefix(500))") }
                if let index = queue.firstIndex(where: { $0.id == request.id && $0.isActive }) {
                    var updated = queue
                    updated[index].failedIDs = failedIDs
                    updated[index].failures = failures
                    do { try replaceQueue(updated) }
                    catch {
                        queue[index].paused = true
                        report(error, bookID: book.id)
                        transfers?.remove(bookID: book.id)
                        return false
                    }
                }
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
            }
        }
        statuses[request.bookID] = Status(
            message: failedIDs.isEmpty ? "缓存完成" : "缓存结束 · \(failedIDs.count) 章失败，可仅重试失败章节",
            isRunning: false, failures: failures, completed: request.chapterIDs.count - failedIDs.count,
            total: request.chapterIDs.count, failedCount: failedIDs.count
        )
        notify()
        return true
    }

    private func replaceQueue(_ updated: [Request]) throws {
        if let queueError { throw SourceError.invalid(queueError) }
        if let queueFile {
            try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: queueFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        queue = updated
    }

    private func suspend(_ request: Request, message: String) {
        guard let index = queue.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = queue
        updated[index].paused = true
        do { try replaceQueue(updated) }
        catch {
            queue[index].paused = true
            report(error, bookID: request.bookID)
            transfers?.remove(bookID: request.bookID)
            return
        }
        statuses[request.bookID] = Status(message: message, isRunning: false)
        transfers?.remove(bookID: request.bookID)
        notify()
    }

    private func report(_ error: Error, bookID: UUID) {
        statuses[bookID] = Status(message: "缓存队列操作未保存：\(error.localizedDescription)",
                                  isRunning: queue.contains { $0.bookID == bookID && $0.isActive })
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .yueduDownloadsChanged, object: self)
    }
}
