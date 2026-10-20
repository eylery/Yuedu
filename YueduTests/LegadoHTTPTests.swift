import XCTest
@testable import Yuedu

@MainActor
final class LegadoHTTPTests: XCTestCase {
    private func fixture(_ response: @escaping (URLRequest) throws -> HTTPFixtureProtocol.Reply) throws -> (LegadoHTTPClient, URL, URLSession, String) {
        let host = "http-\(UUID().uuidString.lowercased()).invalid"
        HTTPFixtureProtocol.install(host: host, handler: response)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPFixtureProtocol.self]
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legado-http-\(UUID())")
        return (LegadoHTTPClient(session: session, cookieDirectory: directory), directory, session, "https://\(host)")
    }

    func testHTTPErrorStatusAndOriginalBinaryBytesRemainAvailable() async throws {
        let bytes = Data([0xff, 0x00, 0x81])
        let (client, directory, session, url) = try fixture { _ in .init(status: 403, data: bytes, headers: ["X-Fixture": "blocked"]) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let response = try await client.request(["url": url], sourceID: UUID())
        XCTAssertEqual(response["status"] as? Int, 403)
        XCTAssertEqual(response["bytes"] as? String, bytes.base64EncodedString())
        XCTAssertEqual((response["headers"] as? [String: String])?["X-Fixture"], "blocked")
    }

    func testGBKQueryFormResponseAndArbitraryHeaders() async throws {
        let gbk = try LegadoHTTPClient.encoding("gbk")
        let data = try XCTUnwrap("中文正文".data(using: gbk))
        let (client, directory, session, url) = try fixture { request in
            XCTAssertEqual(request.url?.query, "q=%D6%D0%CE%C4&next=https://next.invalid/path&already=%2F")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            XCTAssertEqual(HTTPFixtureProtocol.body(request), "q=%D6%D0%CE%C4&word=a+b")
            return .init(data: data, headers: ["Content-Type": "text/html; charset=gbk"])
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let result = try await client.request(["url": url + "?q=中文&next=https://next.invalid/path&already=%2F", "method": "POST", "body": "q=中文&word=a b", "charset": "gbk", "headers": ["Authorization": "Bearer local-fixture", "X-Requested-With": "XMLHttpRequest"]], sourceID: UUID())
        XCTAssertEqual(result["body"] as? String, "中文正文")
    }

    func testJSONObjectAndJSONStringAreNotFormEncoded() async throws {
        let (client, directory, session, url) = try fixture { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
            let json = try JSONSerialization.jsonObject(with: Data(HTTPFixtureProtocol.body(request).utf8)) as? [String: String]
            XCTAssertEqual(json?["name"], "中文")
            return .init(data: Data("{}".utf8))
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        _ = try await client.request(["url": url, "method": "POST", "body": ["name": "中文"]], sourceID: UUID())
        _ = try await client.request(["url": url, "method": "POST", "body": "{\"name\":\"中文\"}"], sourceID: UUID())
    }

    func testHEADHasNoBodyAndUnsafeHeadersFailBeforeSending() async throws {
        let (client, directory, session, url) = try fixture { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(HTTPFixtureProtocol.body(request), "")
            return .init()
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        _ = try await client.request(["url": url, "method": "HEAD", "body": "ignored"], sourceID: UUID())
        for headers in [["Host": "other.invalid"], ["X-Test": "ok\r\nInjected: value"], ["Content-Length": "1"]] {
            do {
                _ = try await client.request(["url": url, "headers": headers], sourceID: UUID())
                XCTFail("Invalid header must be rejected")
            } catch { XCTAssertTrue(error.localizedDescription.contains("请求头")) }
        }
    }

    func testCookieIsolationPersistenceReplacementAndKeyLookup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legado-cookie-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = LegadoHTTPClient(cookieDirectory: directory)
        let first = UUID(), second = UUID()
        let address = "https://cookie.invalid/books"
        _ = try await client.cookie(["action": "set", "url": address, "value": "token=abc; chapter=12; empty="], sourceID: first)
        XCTAssertEqual(client.cookieHeader(for: address, sourceID: second), "")
        XCTAssertEqual(client.cookieHeader(for: "https://sub.cookie.invalid", sourceID: first), "")
        let key = try await client.cookie(["action": "get", "url": address, "key": "chapter"], sourceID: first)
        XCTAssertEqual(key as? String, "12")
        let restored = LegadoHTTPClient(cookieDirectory: directory)
        XCTAssertTrue(restored.cookieHeader(for: address, sourceID: first).contains("token=abc"))
        _ = try await restored.cookie(["action": "replace", "url": address, "value": "new=value"], sourceID: first)
        XCTAssertEqual(restored.cookieHeader(for: address, sourceID: first), "new=value")
        _ = try await restored.cookie(["action": "remove", "url": address], sourceID: first)
        XCTAssertEqual(restored.cookieHeader(for: address, sourceID: first), "")
    }

    func testResponseCookiesAreUsedOnlyForMatchingSourceAndPath() async throws {
        let records = HTTPRequestRecords()
        let (client, directory, session, url) = try fixture { request in
            records.add(request)
            return .init(headers: request.url?.path == "/login" ? ["Set-Cookie": "session=fixture; Path=/books; Secure; HttpOnly"] : [:])
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        _ = try await client.request(["url": url + "/login"], sourceID: source)
        _ = try await client.request(["url": url + "/books/1"], sourceID: source)
        _ = try await client.request(["url": url + "/bookstore"], sourceID: source)
        _ = try await client.request(["url": url + "/books/1"], sourceID: UUID())
        XCTAssertEqual(records.requests[1].value(forHTTPHeaderField: "Cookie"), "session=fixture")
        XCTAssertNil(records.requests[2].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(records.requests[3].value(forHTTPHeaderField: "Cookie"))
    }

    func testDisabledCookieJarStillSendsStoredAndExplicitCookiesButSkipsResponseStorage() async throws {
        let records = HTTPRequestRecords()
        let (client, directory, session, url) = try fixture { request in
            records.add(request)
            return .init(headers: ["Set-Cookie": "fromServer=ignored; Path=/; Secure"])
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let source = UUID()
        _ = try await client.cookie(["action": "set", "url": url, "value": "saved=stillPresent"], sourceID: source)
        _ = try await client.request(["url": url, "cookieJar": false], sourceID: source)
        _ = try await client.request(["url": url, "cookieJar": false, "headers": ["Cookie": "explicit=sent"]], sourceID: source)
        XCTAssertEqual(records.requests[0].value(forHTTPHeaderField: "Cookie"), "saved=stillPresent")
        XCTAssertEqual(records.requests[1].value(forHTTPHeaderField: "Cookie"), "explicit=sent; saved=stillPresent")
        XCTAssertEqual(client.cookieHeader(for: url, sourceID: source), "saved=stillPresent")
        let stored = try await client.cookie(["url": url, "key": "saved"], sourceID: source)
        XCTAssertEqual(stored as? String, "stillPresent")
        _ = try await client.request(["url": url], sourceID: source)
        XCTAssertEqual(records.requests[2].value(forHTTPHeaderField: "Cookie"), "saved=stillPresent")
        XCTAssertTrue(client.cookieHeader(for: url, sourceID: source).contains("fromServer=ignored"))
    }

    func testBareCookieDomainsReadAllMatchingPathsAndRemainSourceIsolated() async throws {
        let (client, directory, session, url) = try fixture { _ in .init(headers: ["Set-Cookie": "session=fixture; Path=/books; Secure; HttpOnly"]) }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let source = UUID(), other = UUID()
        let host = try XCTUnwrap(URL(string: url)?.host)
        _ = try await client.request(["url": url + "/login"], sourceID: source)
        XCTAssertEqual(client.cookieHeader(for: url + "/", sourceID: source), "")
        let scoped = try await client.cookie(["url": host, "key": "session"], sourceID: source)
        XCTAssertEqual(scoped as? String, "fixture")
        _ = try await client.cookie(["action": "set", "url": host, "value": "other=private"], sourceID: other)
        XCTAssertEqual(client.cookieHeader(for: host, sourceID: other), "other=private")
        _ = try await client.cookie(["action": "remove", "url": host], sourceID: source)
        XCTAssertEqual(client.cookieHeader(for: host, sourceID: source), "")
        XCTAssertEqual(client.cookieHeader(for: host, sourceID: other), "other=private")
        for invalid in ["site.invalid/relative", "site.invalid@evil.invalid", "file:///private", "site.invalid:99999"] {
            do { _ = try await client.cookie(["action": "set", "url": invalid, "value": "x=y"], sourceID: source); XCTFail("Malformed cookie host must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Cookie")) }
        }
    }

    func testSingleNumberRateSerializesUntilResponseCompletes() async throws {
        let records = HTTPRequestRecords()
        let (client, directory, session, url) = try fixture { request in
            records.add(request)
            return .init(delay: 0.12)
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        async let first = client.request(["url": url, "concurrentRate": "10"], sourceID: id)
        async let second = client.request(["url": url, "concurrentRate": "10"], sourceID: id)
        _ = try await (first, second)
        XCTAssertEqual(records.times.count, 2)
        XCTAssertGreaterThanOrEqual(records.times[1] - records.times[0], 0.10)
    }

    func testCountRateLimitsStartsInFixedWindow() async throws {
        let records = HTTPRequestRecords()
        let (client, directory, session, url) = try fixture { request in records.add(request); return .init() }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        async let first = client.request(["url": url, "concurrentRate": "2/140"], sourceID: id)
        async let second = client.request(["url": url, "concurrentRate": "2/140"], sourceID: id)
        async let third = client.request(["url": url, "concurrentRate": "2/140"], sourceID: id)
        _ = try await (first, second, third)
        XCTAssertEqual(records.times.count, 3)
        XCTAssertGreaterThanOrEqual(records.times[2] - records.times[0], 0.12)
    }

    func testCancellationAndResponseLimit() async throws {
        let (client, directory, session, url) = try fixture { request in
            request.url?.path == "/large" ? .init(headers: ["Content-Length": "8000001"]) : .init(delay: 2)
        }
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        do { _ = try await client.request(["url": url + "/large"], sourceID: UUID()); XCTFail("Oversized response must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("8 MB")) }
        let task = Task { try await client.request(["url": url], sourceID: UUID()) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAutomaticSearchCannotPresentInteractiveBrowser() async throws {
        let client = LegadoHTTPClient(cookieDirectory: FileManager.default.temporaryDirectory)
        do { _ = try await client.browser(["url": "https://fixture.invalid", "method": "code"], sourceID: UUID()); XCTFail("Interaction must require foreground operation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("登录与设置")) }
    }
}

private final class HTTPRequestRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(URLRequest, TimeInterval)] = []
    func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append((request, ProcessInfo.processInfo.systemUptime)) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values.map(\.0) }
    var times: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values.map(\.1) }
}

private final class HTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var data = Data()
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> Reply] = [:]
    private var work: DispatchWorkItem?
    static func install(host: String, handler: @escaping (URLRequest) throws -> Reply) { lock.lock(); defer { lock.unlock() }; handlers[host] = handler }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let reply = try handler(request)
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !reply.data.isEmpty { self.client?.urlProtocol(self, didLoad: reply.data) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            work = item
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: item)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { work?.cancel(); work = nil }
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
