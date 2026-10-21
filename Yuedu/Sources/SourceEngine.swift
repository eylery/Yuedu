import Foundation
import WebKit
import CoreFoundation

@MainActor
final class SourceEngine {
    static let shared = SourceEngine()
    private let session: URLSession
    private let sourceStore: SourceStore
    private let advancedHTTP: LegadoHTTPClient
    private let runtimeState: LegadoStateStore
    init(session: URLSession? = nil, store: SourceStore? = nil, stateStore: LegadoStateStore? = nil) {
        sourceStore = store ?? SourceStore.shared
        advancedHTTP = LegadoHTTPClient(session: session)
        runtimeState = stateStore ?? .shared
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 45
            configuration.httpMaximumConnectionsPerHost = 3
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(_ url: URL, limit: Int = 8_000_000, headers: [String: String] = [:]) async throws -> (Data, URL) {
        try Task.checkCancellation()
        guard limit > 0 else { throw SourceError.invalid("下载大小上限必须大于 0。") }
        var request = URLRequest(url: url)
        request.setValue("Yuedu-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        for (field, value) in try LegadoRule.validatedHeaders(headers) { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await Self.fetch(request, session: session, limit: limit) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SourceError { throw error }
        catch { throw SourceError.network("无法连接 \(url.host ?? "书源")：\(error.localizedDescription)") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SourceError.network("服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。请检查网址或稍后重试。")
        }
        guard data.count <= limit else { throw SourceError.responseTooLarge(limit: limit, actualBytes: Int64(data.count)) }
        guard !data.isEmpty else { throw SourceError.empty("服务器返回了空内容。") }
        let finalURL = response.url ?? url
        _ = try SourceURL.resolve(finalURL.absoluteString, relativeTo: nil)
        return (data, finalURL)
    }

    func downloadSourceCollection(_ url: URL) async throws -> (Data, URL) {
        try await download(url, limit: SourceImportLimits.maximumBytes)
    }

    nonisolated private static func fetch(_ request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SourceError.network("服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。请检查网址或稍后重试。")
        }
        guard response.expectedContentLength <= Int64(limit) else {
            throw SourceError.responseTooLarge(limit: limit, actualBytes: response.expectedContentLength)
        }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        var chunk = [UInt8]()
        chunk.reserveCapacity(65_536)
        for try await byte in bytes {
            guard data.count + chunk.count < limit else {
                throw SourceError.responseTooLarge(limit: limit, actualBytes: Int64(data.count + chunk.count + 1))
            }
            chunk.append(byte)
            if chunk.count == 65_536 {
                try Task.checkCancellation()
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        data.append(contentsOf: chunk)
        return (data, response)
    }

    func search(source: BookSource, query: String, page: Int = 1, timeout: TimeInterval = 120) async throws -> [SourceSearchResult] {
        try source.validate()
        guard source.enabled else { throw SourceError.invalid("此书源已停用。") }
        let output = try await execute("search", source: source, payload: ["query": query, "page": page], timeout: timeout)
        return try searchResults(output, source: source)
    }

    func loadBook(_ result: SourceSearchResult) async throws -> Book {
        guard let source = sourceStore.source(id: result.sourceID) else { throw SourceError.invalid("此书源已被删除，请重新导入原书源。") }
        return try await loadBook(result, source: source)
    }

    func loadBook(_ result: SourceSearchResult, source: BookSource, timeout: TimeInterval = 120) async throws -> Book {
        try source.validate()
        guard source.enabled else { throw SourceError.invalid("此书源已停用，请先启用。") }
        var context = try Self.object(result.context)
        context["name"] = result.title
        context["author"] = result.author
        context["intro"] = result.summary
        context["bookUrl"] = result.bookURL
        let output = try await execute("book", source: source, payload: ["book": context], timeout: timeout)
        let info = output["book"] as? [String: Any] ?? context
        let rows = output["chapters"] as? [[String: Any]] ?? []
        let chapters = try rows.map { row in
            BookChapter(title: row["title"] as? String ?? "未命名章节", content: "", url: row["url"] as? String, sourceContext: try Self.jsonValues(row["context"]))
        }
        guard !chapters.isEmpty else { throw SourceError.empty("未解析到章节。请检查目录规则或登录状态。") }
        func value(_ key: String, fallback: String) -> String { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        return Book(title: value("name", fallback: result.title), author: value("author", fallback: result.author), summary: value("intro", fallback: result.summary), category: value("kind", fallback: "网络书籍"), coverColor: "517A65", coverSymbol: "leaf", chapters: chapters, sourceName: source.bookSourceName, sourceID: source.id, bookURL: result.bookURL, sourceContext: try Self.jsonValues(info))
    }

    func loadChapter(_ chapter: BookChapter, sourceID: UUID?, book: Book? = nil) async throws -> String {
        if !chapter.content.isEmpty { return chapter.content }
        guard let sourceID, let source = sourceStore.source(id: sourceID) else { throw SourceError.invalid("找不到此书的书源，请重新导入原书源。") }
        return try await loadChapter(chapter, source: source, book: book)
    }

    func loadChapter(_ chapter: BookChapter, source: BookSource, book: Book? = nil, timeout: TimeInterval = 120) async throws -> String {
        let sourceID = source.id
        try source.validate()
        guard source.enabled else { throw SourceError.invalid("此书源已停用，请先启用。") }
        var context = try Self.object(chapter.sourceContext)
        context["title"] = chapter.title
        context["url"] = chapter.url ?? ""
        var bookContext = try Self.object(book?.sourceContext)
        if bookContext.isEmpty, let url = context["bookUrl"] as? String,
           let savedBooks = runtimeState.state(for: sourceID)["books"] as? [String: Any], let saved = savedBooks[url] as? [String: Any] { bookContext = saved }
        if let book {
            bookContext["name"] = book.title; bookContext["author"] = book.author
            bookContext["bookUrl"] = book.bookURL ?? ""; bookContext["durChapterIndex"] = book.progress.chapterIndex
            bookContext["durChapterTitle"] = chapter.title
        }
        let output = try await execute("chapter", source: source, payload: ["book": bookContext, "chapter": context], timeout: timeout)
        guard let content = output["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceError.empty("未解析到正文。") }
        return content
    }

    /// Prepare only requests whose meaning can be established without running
    /// source scripts. All other formats retain the full foreground runtime.
    func backgroundPlans(book: Book, chapters: [BookChapter]) -> [YueduBackgroundTransfer.Plan] {
        guard let id = book.sourceID, let source = sourceStore.source(id: id),
              source.enabled, source.isTextSource else { return [] }
        let state = runtimeState.state(for: id)
        let scriptedFields = ["jsLib", "loginCheckJs", "concurrentRate"]
        guard scriptedFields.allSatisfy({ source.rawFields[$0]?.isEmpty != false }),
              (state["concurrentRate"] as? String ?? "").isEmpty,
              (state["loginHeaders"] as? [String: Any] ?? [:]).isEmpty,
              (source.ruleContent["webJs"] ?? "").isEmpty else { return [] }
        var headers: [String: String] = [:]
        if let raw = source.rawFields["header"], !raw.isEmpty {
            if let object = raw.objectValue {
                guard object.values.allSatisfy({ $0.stringValue != nil }) else { return [] }
                headers = object.compactMapValues(\.stringValue)
            } else if let string = raw.stringValue,
                      let decoded = try? JSONDecoder().decode([String: String].self, from: Data(string.utf8)) {
                headers = decoded
            } else { return [] }
        }
        guard !headers.values.contains("baseUrl") else { return [] }
        return chapters.compactMap { chapter in
            guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = chapter.url, raw.hasPrefix("http://") || raw.hasPrefix("https://"),
                  !["{{", "}}", "@js:", "<", ">"].contains(where: raw.contains),
                  raw.range(of: #",\s*\{"#, options: .regularExpression) == nil,
                  let request = try? advancedHTTP.backgroundRequest(url: raw, headers: headers, sourceID: id) else { return nil }
            return YueduBackgroundTransfer.Plan(bookID: book.id, chapterID: chapter.id, sourceID: id, request: request)
        }
    }

    func categories(source: BookSource) async throws -> [SourceCategory] {
        let result = try await execute("categories", source: source)
        return (result["categories"] as? [[String: Any]] ?? []).compactMap { value in
            guard let title = value["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let url = value["url"] as? String ?? ""
            return SourceCategory(title: title, url: url)
        }
    }

    func explore(source: BookSource, url: String, page: Int = 1) async throws -> [SourceSearchResult] {
        try searchResults(await execute("explore", source: source, payload: ["url": url, "page": page]), source: source)
    }

    func login(source: BookSource, info: [String: String], variable: String?, action: String?) async throws -> [String] {
        var payload: [String: Any] = ["interactive": true, "loginInfo": info]
        if let variable { payload["variable"] = variable }
        if let action { payload["action"] = action }
        let result = try await execute("login", source: source, payload: payload, timeout: 600)
        return result["logs"] as? [String] ?? []
    }

    func runtimeState(for source: BookSource) -> [String: Any] { runtimeState.state(for: source.id) }

    func execute(_ operation: String, source: BookSource, payload: [String: Any] = [:], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard source.isTextSource else { throw SourceError.invalid("已排除漫画、有声、视频等非文字书源。") }
        return try await LegadoRuntime(source: source, http: advancedHTTP, stateStore: runtimeState).run(operation, payload: payload, timeout: timeout)
    }

    func extract(_ data: Data, listRule: String?, fields: [String: String]) async throws -> [[String: String]] {
        let html: String
        if let value = String(data: data, encoding: .utf8) { html = value }
        else {
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            guard let value = String(data: data, encoding: String.Encoding(rawValue: encoding)) else { throw SourceError.invalid("网页编码无法识别。") }
            html = value
        }
        var payload: [String: Any] = ["content": html, "fields": fields]
        if let listRule { payload["listRule"] = listRule }
        let output = try await execute("extract", source: .example, payload: payload)
        guard let rows = output["rows"] as? [[String: String]] else { throw SourceError.invalid("规则解析未返回有效字段。") }
        return rows
    }

    private func searchResults(_ output: [String: Any], source: BookSource) throws -> [SourceSearchResult] {
        try (output["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let title = item["name"] as? String, !title.isEmpty, let url = item["bookUrl"] as? String, !url.isEmpty else { return nil }
            return SourceSearchResult(sourceID: source.id, sourceName: source.bookSourceName, title: title, author: (item["author"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "佚名", summary: item["intro"] as? String ?? "", bookURL: url, context: try Self.jsonValues(item["context"]))
        }
    }
    private static func object(_ values: [String: JSONValue]?) throws -> [String: Any] {
        guard let values else { return [:] }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [String: Any] ?? [:]
    }
    private static func jsonValues(_ value: Any?) throws -> [String: JSONValue]? {
        guard let value else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: value))
    }
}

struct SourceCategory: Hashable {
    let title: String
    let url: String
}
