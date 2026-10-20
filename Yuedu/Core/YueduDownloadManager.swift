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
    }

    private struct Request: Codable {
        var id = UUID()
        var bookID: UUID
        var sourceID: UUID
        var chapterIDs: [UUID]
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
                    statuses[request.bookID] = Status(message: "已恢复缓存任务", isRunning: true)
                }
            } catch {
                // Retain the file for recovery. No task is reported as running.
                for book in self.library.books where book.sourceID != nil {
                    statuses[book.id] = Status(message: "缓存队列读取失败，请重新开始：\(error.localizedDescription)", isRunning: false)
                }
            }
        }
        if observeBackground {
            observe(UIApplication.didEnterBackgroundNotification) { $0.enterBackground() }
            observe(UIApplication.didBecomeActiveNotification) { $0.enterForeground() }
            observe(.libraryChanged) { manager in
                for request in manager.queue where manager.library.book(id: request.bookID)?.sourceID != request.sourceID {
                    manager.pause(bookID: request.bookID)
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
                transfers.retain(books: Set(self.queue.map(\.bookID)))
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
        guard var status = statuses[bookID], status.isRunning else { return statuses[bookID] }
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

    func start(bookID: UUID, startIndex: Int = 0, limit: Int? = nil) {
        guard let book = library.book(id: bookID), let sourceID = book.sourceID,
              statuses[bookID]?.isRunning != true else { return }
        let chapters = book.chapters.dropFirst(min(book.chapters.count, max(0, startIndex)))
            .prefix(max(0, limit ?? book.chapters.count))
        let request = Request(bookID: bookID, sourceID: sourceID, chapterIDs: chapters.map(\.id))
        queue.append(request)
        guard saveQueue(bookID: bookID) else {
            queue.removeAll { $0.id == request.id }
            return
        }
        statuses[bookID] = Status(message: "等待缓存", isRunning: true)
        prepare(request)
        notify()
        runNext()
    }

    private func prepare(_ request: Request) {
        guard usesSourceEngine, let transfers, let book = library.book(id: request.bookID) else { return }
        let ids = Set(request.chapterIDs)
        let chapters = book.chapters.filter { ids.contains($0.id) }
        do { try transfers.enqueue(SourceEngine.shared.backgroundPlans(book: book, chapters: chapters)) }
        catch {
            statuses[book.id]?.message = "后台队列无法保存，将在前台缓存：\(error.localizedDescription)"
        }
    }

    func pause(bookID: UUID) {
        queue.removeAll { $0.bookID == bookID }
        if currentID == bookID { worker?.cancel() }
        transfers?.remove(bookID: bookID)
        statuses[bookID] = Status(message: "已暂停 · 已完成的章节已保存", isRunning: false)
        _ = saveQueue(bookID: bookID)
        notify()
    }

    func pauseAll() {
        for id in queue.map(\.bookID) { pause(bookID: id) }
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
        guard foreground, worker == nil, let request = queue.first else { return }
        currentID = request.bookID
        worker = Task { [weak self] in
            guard let self else { return }
            let completed = await self.download(request)
            if completed {
                self.queue.removeAll { $0.id == request.id }
                self.transfers?.remove(bookID: request.bookID)
                _ = self.saveQueue(bookID: request.bookID)
            }
            self.worker = nil
            self.currentID = nil
            self.runNext()
        }
    }

    /// False means interrupted, leaving the durable request available to resume.
    private func download(_ request: Request) async -> Bool {
        if usesSourceEngine, SourceStore.shared.source(id: request.sourceID)?.enabled != true {
            statuses[request.bookID] = Status(message: "书源已停用或移除，请恢复书源后重试", isRunning: false)
            notify()
            return true
        }
        var failures: [String] = []
        var failedCount = 0
        for (offset, id) in request.chapterIDs.enumerated() {
            if Task.isCancelled { return false }
            guard let book = library.book(id: request.bookID), book.sourceID == request.sourceID,
                  let chapter = book.chapters.first(where: { $0.id == id }) else {
                statuses[request.bookID] = Status(message: "书籍或目录已变化，请重新开始缓存", isRunning: false)
                notify()
                return true
            }
            statuses[request.bookID] = Status(
                message: "正在缓存 \(offset + 1)/\(request.chapterIDs.count) · \(chapter.title)", isRunning: true
            )
            notify()
            if !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
                continue
            }
            do {
                let text = try await load(chapter, book)
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SourceError.empty("未获取到正文")
                }
                let cachedBytes = library.book(id: book.id)?.chapters.reduce(0) { $0 + $1.content.utf8.count } ?? 0
                guard cachedBytes + text.utf8.count <= 100_000_000 else {
                    statuses[book.id] = Status(message: "已达到单本书 100 MB 的批量缓存上限，已完成章节仍可离线阅读。", isRunning: false)
                    notify()
                    return true
                }
                library.updateChapterContent(bookID: book.id, chapterID: chapter.id, text: text)
                if let error = library.persistenceError {
                    statuses[book.id] = Status(message: "缓存停止：\(error)", isRunning: false)
                    notify()
                    return true
                }
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                if Task.isCancelled { return false }
                failedCount += 1
                if failures.count < 30 { failures.append("\(chapter.title)：\(error.localizedDescription)") }
                transfers?.remove(bookID: book.id, chapterID: chapter.id)
            }
        }
        statuses[request.bookID] = Status(
            message: failedCount == 0 ? "缓存完成" : "缓存结束 · \(failedCount) 章失败，可重试未缓存章节",
            isRunning: false, failures: failures
        )
        notify()
        return true
    }

    @discardableResult
    private func saveQueue(bookID: UUID) -> Bool {
        guard let queueFile else { return true }
        do {
            try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(queue).write(to: queueFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            statuses[bookID] = Status(message: "缓存队列保存失败：\(error.localizedDescription)", isRunning: false)
            notify()
            return false
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .yueduDownloadsChanged, object: self)
    }
}
