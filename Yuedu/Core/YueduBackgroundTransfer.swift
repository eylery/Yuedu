import Foundation
import CryptoKit

/// The system owns the network transfers. WebKit source evaluation stays in the
/// foreground; its HTTP bridge consumes these responses after the app resumes.
@MainActor
final class YueduBackgroundTransfer: NSObject, URLSessionDownloadDelegate {
    static let shared = YueduBackgroundTransfer()
    static let identifier = "com.example.yuedu.chapter-downloads.v1"
    nonisolated static let responseLimit = 8_000_000
    nonisolated static let spoolLimit = 200_000_000

    struct Plan {
        let bookID: UUID
        let chapterID: UUID
        let sourceID: UUID
        let request: URLRequest
    }

    struct Summary {
        var waiting = 0
        var transferring = 0
        var ready = 0
        var failed = 0
    }

    private enum State: String, Codable { case queued, transferring, ready, failed }
    private struct Record: Codable {
        var id: UUID
        var bookID: UUID
        var chapterID: UUID
        var sourceID: UUID
        var fingerprint: String
        var url: URL
        var headers: [String: String]
        var state: State
        var responseURL: URL?
        var statusCode: Int?
        var responseHeaders: [String: String]?
        var bytes = 0
        var error: String?
    }

    private let directory: URL
    private let configuration: URLSessionConfiguration
    private var records: [Record] = []
    private var tasks: [UUID: URLSessionTask] = [:]
    private var connected = false
    private var connecting = false
    private var completionHandlers: [() -> Void] = []
    private var eventsFinished = false
    private(set) var persistenceError: String?
    var spooledBytes: Int { records.reduce(0) { $0 + $1.bytes } }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

    init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yuedu/background-transfers", isDirectory: true)
        if let configuration { self.configuration = configuration }
        else {
            let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 7 * 24 * 60 * 60
            config.timeoutIntervalForRequest = 60
            config.httpMaximumConnectionsPerHost = 2
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.configuration = config
        }
        super.init()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            var excluded = self.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifest.path) {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: manifest))
            }
        } catch {
            persistenceError = "后台任务读取失败：\(error.localizedDescription)"
        }
    }

    private var manifest: URL { directory.appendingPathComponent("transfers.json") }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".response") }

    /// Reattach before scheduling new tasks to avoid duplicates after relaunch.
    func connect() async {
        if connected { return }
        if connecting {
            while !connected { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        connecting = true
        let existing = await session.allTasks
        for task in existing {
            guard let description = task.taskDescription, let id = UUID(uuidString: description),
                  let record = records.first(where: { $0.id == id }),
                  record.state == .transferring else {
                task.cancel()
                continue
            }
            tasks[id] = task
            if task.state == .suspended { task.resume() }
        }
        for index in records.indices {
            if records[index].state == .transferring, tasks[records[index].id] == nil {
                records[index].state = .queued
            }
            if records[index].state == .ready,
               !FileManager.default.fileExists(atPath: file(records[index].id).path) {
                records[index].state = .queued
                records[index].bytes = 0
            }
        }
        connected = true
        connecting = false
        saveAndNotify()
        pump()
    }

    func enqueue(_ plans: [Plan]) throws {
        guard persistenceError == nil else { throw SourceError.invalid(persistenceError!) }
        let previous = records
        for plan in plans {
            guard let url = plan.request.url, plan.request.httpMethod == nil || plan.request.httpMethod == "GET" else { continue }
            let fingerprint = Self.fingerprint(plan.request, sourceID: plan.sourceID)
            guard !records.contains(where: {
                $0.bookID == plan.bookID && $0.chapterID == plan.chapterID && $0.fingerprint == fingerprint
            }) else { continue }
            guard records.count < 20_000 else { break }
            records.append(Record(
                id: UUID(), bookID: plan.bookID, chapterID: plan.chapterID, sourceID: plan.sourceID,
                fingerprint: fingerprint, url: url, headers: plan.request.allHTTPHeaderFields ?? [:], state: .queued
            ))
        }
        do { try persist() }
        catch {
            records = previous
            throw error
        }
        pump()
        notify()
    }

    func summary(bookID: UUID) -> Summary {
        var result = Summary()
        for record in records where record.bookID == bookID {
            switch record.state {
            case .queued: result.waiting += 1
            case .transferring: result.transferring += 1
            case .ready: result.ready += 1
            case .failed: result.failed += 1
            }
        }
        return result
    }

    /// Cancelling the caller only stops parsing, never the system's transfer.
    func response(for request: URLRequest, sourceID: UUID) async throws -> (Data, HTTPURLResponse)? {
        let key = Self.fingerprint(request, sourceID: sourceID)
        guard let id = records.first(where: { $0.fingerprint == key })?.id else { return nil }
        while let record = records.first(where: { $0.id == id }) {
            try Task.checkCancellation()
            switch record.state {
            case .ready:
                guard let url = record.responseURL, let status = record.statusCode,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                     headerFields: record.responseHeaders) else {
                    throw SourceError.invalid("后台响应记录不完整，请重新缓存。")
                }
                let data = try Data(contentsOf: file(id), options: .mappedIfSafe)
                guard data.count <= Self.responseLimit else { throw LegadoHTTPError.tooLarge }
                return (data, response)
            case .failed:
                throw SourceError.network(record.error ?? "后台下载失败，请重试。")
            case .queued, .transferring:
                if let persistenceError { throw SourceError.invalid(persistenceError) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try Task.checkCancellation()
        return nil
    }

    func remove(bookID: UUID, chapterID: UUID? = nil) {
        let removed = records.filter { $0.bookID == bookID && (chapterID == nil || $0.chapterID == chapterID) }
        guard !removed.isEmpty else { return }
        records.removeAll { $0.bookID == bookID && (chapterID == nil || $0.chapterID == chapterID) }
        for record in removed {
            tasks.removeValue(forKey: record.id)?.cancel()
            try? FileManager.default.removeItem(at: file(record.id))
        }
        saveAndNotify()
        pump()
    }

    func retain(books: Set<UUID>) {
        for id in Set(records.map(\.bookID)).subtracting(books) { remove(bookID: id) }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func handleEvents(completion: @escaping () -> Void) {
        completionHandlers.append(completion)
        _ = session
        if eventsFinished { finishEvents() }
    }

    private func pump() {
        guard connected, persistenceError == nil else { return }
        var reserved = records.reduce(0) { $0 + $1.bytes } + tasks.count * Self.responseLimit
        var created: [URLSessionDownloadTask] = []
        for index in records.indices where records[index].state == .queued {
            guard tasks.count < 16, reserved + Self.responseLimit <= Self.spoolLimit else { break }
            var request = URLRequest(url: records[index].url)
            request.allHTTPHeaderFields = records[index].headers
            request.httpShouldHandleCookies = false
            let task = session.downloadTask(with: request)
            task.taskDescription = records[index].id.uuidString
            tasks[records[index].id] = task
            records[index].state = .transferring
            reserved += Self.responseLimit
            created.append(task)
        }
        guard !created.isEmpty else { return }
        do {
            try persist()
            created.forEach { $0.resume() }
        } catch {
            created.forEach { $0.cancel() }
            persistenceError = "后台任务保存失败：\(error.localizedDescription)"
        }
        notify()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // DelegateQueue is main. Move the temporary file before returning.
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)),
                  let index = records.firstIndex(where: { $0.id == id }) else { return }
            do {
                guard let http = downloadTask.response as? HTTPURLResponse, let url = http.url else {
                    throw SourceError.network("后台请求没有返回 HTTP 响应。")
                }
                let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.responseLimit else { throw LegadoHTTPError.tooLarge }
                let target = file(id)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path
                )
                records[index].responseURL = url
                records[index].statusCode = http.statusCode
                records[index].responseHeaders = http.allHeaderFields.reduce(into: [:]) { result, entry in
                    result[String(describing: entry.key)] = String(describing: entry.value)
                }
                records[index].bytes = size
                records[index].state = .ready
            } catch {
                try? FileManager.default.removeItem(at: file(id))
                records[index].state = .failed
                records[index].error = error.localizedDescription
            }
            saveAndNotify()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > Self.responseLimit || totalBytesExpectedToWrite > Self.responseLimit else { return }
        downloadTask.cancel()
        MainActor.assumeIsolated {
            guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)),
                  let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].state = .failed
            records[index].error = "章节响应超过 8 MB，已停止下载。"
            saveAndNotify()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
            tasks.removeValue(forKey: id)
            if let index = records.firstIndex(where: { $0.id == id }), records[index].state == .transferring {
                records[index].state = .failed
                records[index].error = error?.localizedDescription ?? "下载未能保存，请重试。"
            }
            saveAndNotify()
            pump()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            eventsFinished = true
            finishEvents()
        }
    }

    private func finishEvents() {
        guard !completionHandlers.isEmpty else { return }
        saveAndNotify()
        let handlers = completionHandlers
        completionHandlers.removeAll()
        eventsFinished = false
        handlers.forEach { $0() }
    }

    private func persist() throws {
        try JSONEncoder().encode(records).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func saveAndNotify() {
        guard persistenceError == nil else { notify(); return }
        do { try persist() }
        catch { persistenceError = "后台任务保存失败：\(error.localizedDescription)" }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .yueduDownloadsChanged, object: self)
    }

    static func fingerprint(_ request: URLRequest, sourceID: UUID) -> String {
        let headers = (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        let identity = [sourceID.uuidString, request.httpMethod ?? "GET", request.url?.absoluteString ?? "",
                        headers, request.httpBody?.base64EncodedString() ?? ""].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
