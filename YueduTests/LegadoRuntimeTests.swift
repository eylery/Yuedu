import XCTest
@testable import Yuedu

@MainActor
final class LegadoRuntimeTests: XCTestCase {
    private func fixture(_ fields: [String: Any] = [:]) throws -> (SourceEngine, BookSource, URL, URLSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legado-runtime-\(UUID())")
        let store = SourceStore(directory: directory)
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(BookSource.example)) as? [String: Any])
        config["bookSourceUrl"] = "https://runtime.fixture.invalid/"
        config["enabled"] = true
        fields.forEach { config[$0.key] = $0.value }
        let source = try XCTUnwrap(SourceStore.decode(JSONSerialization.data(withJSONObject: config)).first)
        try store.save(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let engine = SourceEngine(session: session, store: store, stateStore: LegadoStateStore(directory: directory))
        return (engine, source, directory, session)
    }

    func testSynchronousNativeUtilitiesAndJavaClassAdapters() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("evaluate", source: source, payload: ["script": #"JSON.stringify({md5:java.md5Encode('abc'), gbk:java.bytesToStr(new Packages.java.lang.String('中文').getBytes('GBK'),'GBK'), base64:java.base64Decode(java.base64Encode('春日')), aes:java.createSymmetricCrypto('AES/CBC/PKCS5Padding','1234567890123456','1234567890123456').decryptStr(java.createSymmetricCrypto('AES/CBC/PKCS5Padding','1234567890123456','1234567890123456').encryptBase64('合成正文'))})"#])
        let data = Data(try XCTUnwrap(output["value"] as? String).utf8)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(value, ["md5": "900150983cd24fb0d6963f7d28e17f72", "gbk": "中文", "base64": "春日", "aes": "合成正文"])
    }

    func testRelativeGBKPOSTAndDynamicHeaderReachHTTPWithoutUTF8Reencoding() async throws {
        let (engine, source, directory, session) = try fixture(["header": "@js:JSON.stringify({'X-Fixture': java.md5Encode('abc')})"])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("request", source: source, payload: ["query": "中文", "url": #"/echo?q={{key}},{"method":"POST","body":"word={{key}}","charset":"GBK"}"#])
        let response = try XCTUnwrap(output["response"] as? [String: Any])
        let echo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((response["body"] as? String ?? "").utf8)) as? [String: String])
        XCTAssertEqual(echo["query"], "q=%D6%D0%CE%C4")
        XCTAssertEqual(echo["body"], "word=%D6%D0%CE%C4")
        XCTAssertEqual(echo["header"], "900150983cd24fb0d6963f7d28e17f72")
    }

    func testScriptHTTPCallsAreSynchronousAndLoginCheckSeesErrorResponses() async throws {
        let (engine, source, directory, session) = try fixture(["loginCheckJs": "@js:java.log('status='+result.code()); result;"])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("evaluate", source: source, payload: ["script": #"var first=JSON.parse(java.ajax('/value')); first.number + JSON.parse(java.get('/value',{}).body()).number"#])
        XCTAssertEqual(output["value"] as? Int, 14)
        let denied = try await engine.execute("request", source: source, payload: ["url": "/denied"])
        XCTAssertEqual((denied["response"] as? [String: Any])?["status"] as? Int, 403)
        XCTAssertEqual(denied["logs"] as? [String], ["status=403"])
    }

    func testLoginUIActionsVariablesAndCachePersistBetweenOperations() async throws {
        let (engine, source, directory, session) = try fixture([
            "loginUi": "@js:JSON.stringify([{name:'账号',type:'text'},{name:'应用',type:'button',action:'login()'}])",
            "loginUrl": "@js:function login(){ source.putLoginHeader(JSON.stringify({'X-User':source.getLoginInfoMap().get('账号')}));cache.put('saved','fixture');java.log(source.getVariable()); }"
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let ui = try await engine.execute("loginUI", source: source, payload: ["interactive": true])
        XCTAssertEqual((ui["items"] as? [[String: Any]])?.count, 2)
        let logs = try await engine.login(source: source, info: ["账号": "local-user"], variable: "server-option", action: "login()")
        XCTAssertEqual(logs, ["server-option"])
        let output = try await engine.execute("evaluate", source: source, payload: ["script": "source.getLoginHeaderMap().get('X-User') + '|' + cache.get('saved') + '|' + source.getVariable()"])
        XCTAssertEqual(output["value"] as? String, "local-user|fixture|server-option")
        let restored = LegadoStateStore(directory: directory).state(for: source.id)
        XCTAssertEqual((restored["loginInfo"] as? [String: String])?["账号"], "local-user")
    }

    func testJSONScriptSearchPagedCatalogAndPagedHTMLContentPreserveContext() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "@js:java.put('prefix','共享'); '/search';",
            "ruleSearch": ["bookList": "$.books", "name": "$.name@put:{token:'$.token'}", "author": "$.author", "bookUrl": "$.url"],
            "ruleBookInfo": ["name": "$.name", "tocUrl": "$.toc"],
            "ruleToc": ["chapterList": "$.chapters", "chapterName": "$.title", "chapterUrl": "$.url@put:{chapterToken:'$.token'}", "nextTocUrl": "$.next"],
            "ruleContent": ["content": "#content@html", "nextContentUrl": "a.next@href", "replaceRegex": "##广告", "callBackJs": "@js:java.log(java.get('token')+'|'+java.get('chapterToken'));" ]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let results = try await engine.search(source: source, query: "合成")
        XCTAssertEqual(results.count, 1)
        let book = try await engine.loadBook(XCTUnwrap(results.first), source: source)
        XCTAssertEqual(book.title, "合成故事")
        XCTAssertEqual(book.chapters.map(\.title), ["第一章", "第二章"])
        let chapter = try XCTUnwrap(book.chapters.first)
        let content = try await engine.loadChapter(chapter, sourceID: source.id, book: book)
        XCTAssertTrue(content.contains("第一段"))
        XCTAssertTrue(content.contains("第二段"))
        XCTAssertFalse(content.contains("广告"))
        XCTAssertEqual(chapter.sourceContext?["__variables"]?.objectValue?["chapterToken"], .string("c1"))
        XCTAssertEqual(book.sourceContext?["__variables"]?.objectValue?["token"], .string("book-token"))
    }

    func testBinaryAndDataURLResponsesUseLegadoTypeOption() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("request", source: source, payload: ["url": "data:;base64,5Lit5paH,{\"type\":\"text\"}"])
        XCTAssertEqual((output["response"] as? [String: Any])?["body"] as? String, "e4b8ade69687")
    }

    func testJavaGetStringExplicitContentAndURLFlag() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("evaluate", source: source, payload: ["content": "<a href='/first'>甲</a><a href='/second'>乙</a>", "script": #"java.getString('p@text','<p>显式上下文</p>')+'|'+java.getString('a@href',true)"#])
        XCTAssertEqual(output["value"] as? String, "显式上下文|https://runtime.fixture.invalid/first")
    }

    func testScriptVariablesUseJavaStringConversionAndMissingCacheIsNull() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("evaluate", source: source, payload: ["script": "java.put('pair',['signature',123]); java.get('pair').split(',')[1] + '|' + (cache.getFromMemory('missing') === null)"])
        XCTAssertEqual(output["value"] as? String, "123|true")
    }

    func testAESFourArgumentLegacySignatureAndRenderedWebView() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("evaluate", source: source, payload: ["script": #"var encrypted=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','1234567890123456','6543210987654321').encryptBase64('四参数');java.aesBase64DecodeToString(encrypted,'1234567890123456','AES/CBC/PKCS5Padding','6543210987654321')"#])
        XCTAssertEqual(output["value"] as? String, "四参数")
        let rendered = try await engine.execute("request", source: source, payload: ["url": "/render", "options": ["webView": true, "html": "<html><body><p id='value'>初始</p><script>document.getElementById('value').textContent='动态正文'</script></body></html>", "webJs": "document.getElementById('value').textContent"]])
        XCTAssertEqual((rendered["response"] as? [String: Any])?["body"] as? String, "动态正文")
    }

    func testBrowserAdapterParsesOptionsAndReturnsResponseMethods() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let script = #"""
        globalThis.prompt=function(name,json){var call=JSON.parse(json);return JSON.stringify({value:{body:call.payload.headers['X-Local'],url:call.payload.url,status:200,headers:{},bytes:''}})};
        var response=java.startBrowserAwait('/login,{"headers":{"X-Local":"fixture"}}','Login',false);
        response.body()+'|'+response.url()+'|'+response.code();
        """#
        let output = try await engine.execute("evaluate", source: source, payload: ["script": script])
        XCTAssertEqual(output["value"] as? String, "fixture|https://runtime.fixture.invalid/login|200")
    }

    func testLoginCheckCanReplayPOSTAfterCookieChangeAndReplaceStatus() async throws {
        let (engine, source, directory, session) = try fixture(["loginCheckJs": "@js:if(result.code()===403){cookie.setCookie(baseUrl,'retry=ok');java.initUrl();result=java.getStrResponse();}result;"])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let output = try await engine.execute("request", source: source, payload: ["url": #"/retry,{"method":"POST","body":"q=中文","charset":"GBK"}"#])
        let response = try XCTUnwrap(output["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertEqual(response["body"] as? String, "POST|q=%D6%D0%CE%C4")
    }

    func testSearchURLVariablesReachFieldsAndRuntimeComicResultsAreExcluded() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "@js:java.put('label','共享');'/search'",
            "ruleSearch": ["bookList": "$.books", "name": "$.name@js:java.get('label')+result", "bookUrl": "$.url"],
            "ruleBookInfo": ["tocUrl": "$.toc"],
            "ruleToc": ["chapterList": "$.chapters", "chapterName": "$.title", "chapterUrl": "$.url@js:book.setType(64);result"]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let results = try await engine.search(source: source, query: "合成")
        XCTAssertEqual(results.first?.title, "共享合成故事")
        do { _ = try await engine.loadBook(XCTUnwrap(results.first), source: source); XCTFail("A source changing its result to comic must be excluded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已排除")) }
    }

    func testMultilineRequestOptionsSurviveExtractedBookLinks() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "/search",
            "ruleSearch": ["bookList": "$.books", "name": "$.name", "bookUrl": "$.url@js:result + ',{\\n\"method\":\"POST\",\\n\"body\":\"id=1\"\\n}'"]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let result = try await engine.search(source: source, query: "合成")
        XCTAssertEqual(result.first?.bookURL, "https://runtime.fixture.invalid/book,{\"method\":\"POST\",\"body\":\"id=1\"}")
    }

    func testCatalogOrderPrefixAndBookReverseApplyIndependently() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "/search",
            "ruleSearch": ["bookList": "$.books", "name": "$.name", "bookUrl": "$.url"],
            "ruleBookInfo": ["tocUrl": "$.toc", "name": "$.name@js:book.setReverseToc(true);result"],
            "ruleToc": ["chapterList": "-$.chapters", "chapterName": "$.title", "chapterUrl": "$.url", "nextTocUrl": "$.next"]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let result = try await engine.search(source: source, query: "合成")
        let book = try await engine.loadBook(XCTUnwrap(result.first), source: source)
        XCTAssertEqual(book.chapters.map(\.title), ["第一章", "第二章"])
        var forward = source
        forward.ruleBookInfo["name"] = "$.name@js:book.setReverseToc(false);result"
        forward.ruleToc["chapterList"] = "+$.chapters"
        let forwardBook = try await engine.loadBook(XCTUnwrap(result.first), source: forward)
        XCTAssertEqual(forwardBook.chapters.map(\.title), ["第一章", "第二章"])
    }

    func testSearchCanReturnDetailPageAndIgnoreBrokenOptionalMetadata() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "/book", "bookUrlPattern": ".*/book$",
            "ruleBookInfo": ["name": "$.name", "kind": "@js:throw Error('optional metadata');", "tocUrl": "$.toc"]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let direct = try await engine.search(source: source, query: "合成")
        XCTAssertEqual(direct.first?.title, "合成故事")
        XCTAssertEqual(direct.first?.bookURL, "https://runtime.fixture.invalid/book")
        var fallback = source
        fallback.rawFields.removeValue(forKey: "bookUrlPattern")
        let emptyListFallback = try await engine.search(source: fallback, query: "合成")
        XCTAssertEqual(emptyListFallback.first?.title, "合成故事")
        fallback.searchUrl = "/search"
        fallback.ruleSearch["kind"] = "@js:throw Error('optional metadata');"
        let normal = try await engine.search(source: fallback, query: "合成")
        XCTAssertEqual(normal.first?.title, "合成故事")
    }

    func testChapterMutationsSurviveOlderBookshelfContext() async throws {
        let (engine, source, directory, session) = try fixture([
            "searchUrl": "/search",
            "ruleSearch": ["bookList": "$.books", "name": "$.name", "bookUrl": "$.url"],
            "ruleBookInfo": ["name": "$.name@js:book.variable='';book.putVariable('count','0');result", "tocUrl": "$.toc"],
            "ruleToc": ["chapterList": "$.chapters", "chapterName": "$.title", "chapterUrl": "$.url", "nextTocUrl": "$.next"],
            "ruleContent": ["content": "@js:book.variable+=chapter.title;book.putVariable('count',Number(book.getVariable('count'))+1);book.variable+'|'+book.getVariable('count')"]
        ])
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let results = try await engine.search(source: source, query: "合成")
        let book = try await engine.loadBook(XCTUnwrap(results.first), source: source)
        let first = try await engine.loadChapter(book.chapters[0], sourceID: source.id, book: book)
        let second = try await engine.loadChapter(book.chapters[1], sourceID: source.id, book: book)
        XCTAssertEqual(first, "第一章|1")
        XCTAssertEqual(second, "第一章第二章|2")
    }

    func testTimeoutStopsRunAndFollowingOperationStillWorks() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        do {
            _ = try await engine.execute("evaluate", source: source, payload: ["script": "while(true){}"], timeout: 1)
            XCTFail("Infinite loop should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("时间上限")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let output = try await engine.execute("evaluate", source: source, payload: ["script": "6 * 7"], timeout: 5)
        XCTAssertEqual(output["value"] as? Int, 42)
    }

    func testCancellationReturnsPromptlyDuringNativeSleep() async throws {
        let (engine, source, directory, session) = try fixture()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let operation = Task { try await engine.execute("evaluate", source: source, payload: ["script": "Packages.java.lang.Thread.sleep(10000); 'done'"], timeout: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class RuntimeFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "runtime.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case "/echo":
            let value = ["query": request.url?.query ?? "", "body": Self.requestBody(request), "header": request.value(forHTTPHeaderField: "X-Fixture") ?? ""]
            body = String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        case "/value": body = "{\"number\":7}"
        case "/denied": body = "login needed"
        case "/retry": body = (request.httpMethod ?? "") + "|" + Self.requestBody(request)
        case "/search": body = #"{"books":[{"name":"合成故事","author":"本地作者","url":"/book","token":"book-token"}]}"#
        case "/book": body = #"{"name":"合成故事","toc":"/toc"}"#
        case "/toc": body = #"{"chapters":[{"title":"第一章","url":"/chapter","token":"c1"}],"next":"/toc2"}"#
        case "/toc2": body = #"{"chapters":[{"title":"第二章","url":"/chapter2","token":"c2"}],"next":"/toc"}"#
        case "/chapter": body = #"<div id="content"><p>第一段广告</p></div><a class="next" href="/chapter-next">下一页</a>"#
        case "/chapter-next": body = #"<div id="content"><p>第二段</p></div><a class="next" href="/chapter">循环链接</a>"#
        default: body = "{}"
        }
        let denied = path == "/denied" || path == "/retry" && request.value(forHTTPHeaderField: "Cookie")?.contains("retry=ok") != true
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: denied ? 403 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
    private static func requestBody(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let length = stream.read(&buffer, maxLength: buffer.count)
            if length <= 0 { break }
            data.append(contentsOf: buffer.prefix(length))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
