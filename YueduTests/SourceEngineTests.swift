import XCTest
@testable import Yuedu

@MainActor
final class SourceEngineTests: XCTestCase {
    private func makeStore() throws -> (SourceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SourceStore(directory: directory), directory)
    }

    func testJSONPathTraversesArraysAndQuotedKeys() throws {
        let json: [String: Any] = ["data": ["books": [["name": "春日", "chapter.count": 2], ["name": "夏夜", "chapter.count": 5]]]]
        XCTAssertEqual(try SimpleJSONPath.text("$.data.books[*].name", in: json), "春日\n夏夜")
        XCTAssertEqual(try SimpleJSONPath.text("$.data.books[1]['chapter.count']", in: json), "5")
        XCTAssertEqual(try SimpleJSONPath.text("$.data.books[8].name", in: json), "")
        XCTAssertThrowsError(try SimpleJSONPath.tokens("$..name"))
        XCTAssertThrowsError(try SimpleJSONPath.tokens("$.books[?(@.name)]"))
    }

    func testSimpleURLHelperEscapesReservedCharactersAndRejectsUnsafeSchemes() throws {
        let url = try SourceURL.search("/search?q={{key}}&page={{page}}", key: "山海 &?#/", page: 3, base: "https://fixture.invalid")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "q" })?.value, "山海 &?#/")
        XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "3")
        XCTAssertThrowsError(try SourceURL.search("/search,{'method':'POST'}", key: "book", page: 1, base: "https://fixture.invalid"))
        XCTAssertThrowsError(try SourceURL.resolve("file:///etc/passwd", relativeTo: nil))
        // SourceURL is the legacy plain-URL helper. Script/POST/XPath support is
        // exercised through the source model and dedicated Legado runtime tests.
    }

    func testImportIsAtomicUpdatesIdentityAndPersistsEnabledState() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = BookSource.example
        source.bookSourceUrl = "https://fixture.invalid"
        try store.importData(SourceStore.encode(source))
        let id = try XCTUnwrap(store.sources.first?.id)
        source.id = UUID()
        source.bookSourceName = "更新后的书源"
        try store.importData(SourceStore.encode(source))
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertEqual(store.sources.first?.id, id)
        try store.setEnabled(id: id, enabled: true)
        let reopened = SourceStore(directory: directory)
        XCTAssertEqual(reopened.sources.first?.enabled, true)
        var invalid = source
        invalid.bookSourceUrl = "https://other.invalid"
        invalid.bookSourceName = " "
        XCTAssertThrowsError(try store.importData(SourceStore.encode([source, invalid])))
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertEqual(store.sources.first?.enabled, true)
    }

    func testLegadoImportWithoutIDRetainsIdentityAfterDeleteAndReimport() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(BookSource.example)) as? [String: Any])
        object.removeValue(forKey: "id")
        let data = try JSONSerialization.data(withJSONObject: object)
        try store.importData(data)
        let id = try XCTUnwrap(store.sources.first?.id)
        try store.remove(id: id)
        try store.importData(data)
        XCTAssertEqual(store.sources.first?.id, id)
    }

    func testImportedRequestScriptsArePreservedAndRemainEnabled() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(BookSource.example)) as? [String: Any])
        object["header"] = "@js:someCode()"
        object["enabled"] = true
        let sources = try SourceStore.decode(JSONSerialization.data(withJSONObject: object))
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(source.enabled)
        XCTAssertTrue(source.isCompatible)
        XCTAssertTrue(source.compatibilityIssues.isEmpty)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(source)) as? [String: Any])
        XCTAssertEqual(exported["header"] as? String, "@js:someCode()")
    }

    func testCSSExtractsListAndParagraphsWithoutExecutingSiteScript() async throws {
        let engine = SourceEngine()
        let html = #"""
        <script>document.body.innerHTML = '<div class="item"><a href="/bad">坏结果</a></div>';</script>
        <style>.item { display:none }</style>
        <div class="item"><a href="/book/1">春日手记</a><span class="author">某作者</span></div>
        <div id="content"><p>第一段</p><p>第二段<br>第三行</p></div>
        """#
        let rows = try await engine.extract(Data(html.utf8), listRule: ".item", fields: ["name": "a@text", "url": "a@href", "author": ".author@text"])
        XCTAssertEqual(rows, [["name": "春日手记", "url": "/book/1", "author": "某作者"]])
        let content = try await engine.extract(Data(html.utf8), listRule: nil, fields: ["content": "#content@text"])
        XCTAssertEqual(content.first?["content"], "第一段 第二段 第三行")
    }

    func testJSONSearchToCatalogToChapterAndHTTPFailure() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = BookSource.example
        source.bookSourceUrl = "https://fixture.invalid"
        source.enabled = true
        try store.save(source)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let engine = SourceEngine(session: URLSession(configuration: config), store: store)
        let results = try await engine.search(source: source, query: "春日")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.bookURL, "https://fixture.invalid/book/1")
        let book = try await engine.loadBook(XCTUnwrap(results.first))
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].url, "https://fixture.invalid/chapter/1")
        let content = try await engine.loadChapter(book.chapters[0], sourceID: source.id)
        XCTAssertEqual(content, "第一段\n\n第二段")
        let cached = try await engine.loadChapter(BookChapter(title: "缓存", content: "离线正文"), sourceID: nil)
        XCTAssertEqual(cached, "离线正文")
        do {
            _ = try await engine.download(URL(string: "https://fixture.invalid/fail")!)
            XCTFail("HTTP 503 must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
        do {
            _ = try await engine.download(URL(string: "https://fixture.invalid/large")!, limit: 3)
            XCTFail("Streaming limit must reject an oversized response")
        } catch { XCTAssertTrue(error.localizedDescription.contains("大小") || error.localizedDescription.contains("超过")) }
    }

    func testLargeSourceCollectionDownloadsImportsAsynchronouslyAndPersists() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session, store: store)

        let (data, _) = try await engine.downloadSourceCollection(URL(string: "https://fixture.invalid/large-source-collection")!)
        XCTAssertGreaterThan(data.count, 2_000_000, "Fixture must exercise the former 2 MB limit.")
        XCTAssertLessThan(data.count, SourceImportLimits.maximumBytes)
        let report = try await store.importDataAsync(data)
        let imported = report.importedCount
        XCTAssertEqual(imported, SourceImportRegressionFixture.largeCollectionCount)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertGreaterThan(store.sources.count, 200, "Fixture must exercise the former 200-source limit.")
        XCTAssertEqual(Set(store.sources.map(\.bookSourceUrl)).count, imported)
        XCTAssertEqual(Set(store.sources.map(\.id)).count, imported)
        XCTAssertEqual(store.sources.first?.bookSourceName, "Fixture 0")
        XCTAssertEqual(store.sources.last?.bookSourceName, "Fixture 200")
        let reopened = SourceStore(directory: directory)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.sources, store.sources, "Every imported source must survive reopening the store.")

        let inputFile = directory.appendingPathComponent("large-collection.json")
        try data.write(to: inputFile)
        let fileStoreDirectory = directory.appendingPathComponent("file-import", isDirectory: true)
        let fileStore = SourceStore(directory: fileStoreDirectory)
        let importedFromFile = try await fileStore.importFile(inputFile)
        XCTAssertEqual(importedFromFile.importedCount, imported)
        XCTAssertEqual(SourceStore(directory: fileStoreDirectory).sources, store.sources, "File imports must share the enlarged collection limit and persist the same result.")
    }

    func testCollectionOverSourceCountLimitLeavesMemoryAndDiskUnchanged() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = BookSource.example
        try store.save(original)
        let fileURL = directory.appendingPathComponent("sources.json")
        let before = try Data(contentsOf: fileURL)
        // Repeating a compact, valid object avoids 10,001 separate model instances
        // and proves that the collection limit is checked before deduplication.
        let item = Data(SourceImportRegressionFixture.minimalSource.utf8)
        let count = SourceImportLimits.maximumSourceCount + 1
        var collection = Data()
        collection.reserveCapacity((item.count + 1) * count + 2)
        collection.append(0x5b)
        for index in 0..<count {
            if index > 0 { collection.append(0x2c) }
            collection.append(item)
        }
        collection.append(0x5d)
        XCTAssertLessThan(collection.count, SourceImportLimits.maximumBytes, "This must hit the count limit, not the byte limit.")

        do {
            _ = try await store.importDataAsync(collection)
            XCTFail("A collection containing one more source than the limit must be rejected.")
        } catch let error as SourceError {
            guard case let .invalid(message) = error else { return XCTFail("Expected a source-count validation error, got \(error)") }
            XCTAssertTrue(message.contains(String(SourceImportLimits.maximumSourceCount)))
            XCTAssertTrue(message.contains(String(count)))
        }
        XCTAssertEqual(store.sources, [original])
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "A rejected import must not write a partial collection.")
        XCTAssertNil(store.persistenceError)
    }

    func testKnownAndUnknownLengthOversizeResponsesPreserveSpecificError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session)
        for path in ["/limit-known", "/limit-unknown"] {
            do {
                _ = try await engine.download(URL(string: "https://fixture.invalid" + path)!, limit: 7)
                XCTFail("An eight-byte response must exceed the seven-byte cap: \(path)")
            } catch let error as SourceError {
                guard case let .responseTooLarge(limit, actualBytes) = error else {
                    XCTFail("Expected responseTooLarge, not a wrapped network error: \(error)")
                    continue
                }
                XCTAssertEqual(limit, 7)
                XCTAssertEqual(actualBytes, 8)
                XCTAssertFalse(error.localizedDescription.contains("无法连接"))
            }
        }
    }

    func testExactlyAtDownloadLimitSucceedsWithAndWithoutContentLength() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session)
        for path in ["/limit-known", "/limit-unknown"] {
            let (data, finalURL) = try await engine.download(URL(string: "https://fixture.invalid" + path)!, limit: 8)
            XCTAssertEqual(data, Data("abcdefgh".utf8))
            XCTAssertEqual(finalURL.path, path)
        }
    }

    func testSourceCollectionAndPageDownloadsRetainSeparateLimits() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session)
        // Header-only fixtures reject immediately; no 8 MB or 50 MB body is built.
        do {
            _ = try await engine.download(URL(string: "https://fixture.invalid/over-page-limit")!)
            XCTFail("The ordinary page download cap should remain 8 MB.")
        } catch let error as SourceError {
            guard case let .responseTooLarge(limit, actualBytes) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(limit, 8_000_000)
            XCTAssertEqual(actualBytes, 8_000_001)
        }
        do {
            _ = try await engine.downloadSourceCollection(URL(string: "https://fixture.invalid/over-source-limit")!)
            XCTFail("A source collection exceeding its declared cap must be rejected.")
        } catch let error as SourceError {
            guard case let .responseTooLarge(limit, actualBytes) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(limit, SourceImportLimits.maximumBytes)
            XCTAssertEqual(actualBytes, Int64(SourceImportLimits.maximumBytes + 1))
        }
    }

    func testCancelledDownloadRemainsCancellationInsteadOfConnectionFailure() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SourceFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session)
        do {
            _ = try await engine.downloadSourceCollection(URL(string: "https://fixture.invalid/cancelled")!)
            XCTFail("A cancelled URLSession request must not succeed.")
        } catch is CancellationError { }
        catch { XCTFail("Expected CancellationError, not \(error)") }

        let cancelled = Task { try await engine.downloadSourceCollection(URL(string: "https://fixture.invalid/limit-known")!) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A task cancelled before it starts must not succeed.")
        } catch is CancellationError { }
        catch { XCTFail("Expected CancellationError, not \(error)") }
    }
}

private enum SourceImportRegressionFixture {
    static let largeCollectionCount = 201
    static let minimalSource = #"{"bookSourceName":"Fixture","bookSourceUrl":"https://fixture.invalid","searchUrl":"/?q={{key}}","ruleSearch":{"bookList":"$.b","name":"$.n","bookUrl":"$.u"},"ruleToc":{"chapterList":"$.c","chapterName":"$.n","chapterUrl":"$.u"},"ruleContent":{"content":"$.c"}}"#

    static let largeCollection: Data = {
        // About 2.2 MB total, using meaningful persisted metadata rather than
        // whitespace which could disappear before exercising the store writer.
        let group = String(repeating: "g", count: 10_400)
        let objects: [[String: Any]] = (0..<largeCollectionCount).map { index in
            [
                "bookSourceName": "Fixture \(index)",
                "bookSourceUrl": "https://source-\(index).fixture.invalid",
                "bookSourceGroup": group,
                "searchUrl": "/?q={{key}}",
                "ruleSearch": ["bookList": "$.b", "name": "$.n", "bookUrl": "$.u"],
                "ruleToc": ["chapterList": "$.c", "chapterName": "$.n", "chapterUrl": "$.u"],
                "ruleContent": ["content": "$.c"]
            ]
        }
        return try! JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    }()
}

private final class SourceFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if url.path == "/large-source-collection" {
            let data = SourceImportRegressionFixture.largeCollection
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.path == "/over-page-limit" || url.path == "/over-source-limit" {
            let length = url.path == "/over-page-limit" ? 8_000_001 : SourceImportLimits.maximumBytes + 1
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(length)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status: Int
        let text: String
        var headers = ["Content-Type": "application/json"]
        switch url.path {
        case "/search":
            status = 200
            text = #"{"books":[{"name":"春日手记","author":"某作者","url":"/book/1","intro":"简介"}]}"#
        case "/book/1":
            status = 200
            text = #"{"tocUrl":"/toc/1"}"#
        case "/toc/1":
            status = 200
            text = #"{"chapters":[{"title":"第一章","url":"/chapter/1"},{"title":"第二章","url":"/chapter/2"},{"title":"重复章节","url":"/chapter/1"}]}"#
        case "/chapter/1":
            status = 200
            text = #"{"content":"第一段\n\n第二段"}"#
        case "/large":
            status = 200
            text = "abcdefg"
        case "/limit-known", "/limit-unknown":
            status = 200
            text = "abcdefgh"
            if url.path == "/limit-known" { headers["Content-Length"] = "8" }
        default:
            status = 503
            text = "Unavailable"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
