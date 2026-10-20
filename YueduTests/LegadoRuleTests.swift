import XCTest
@testable import Yuedu

@MainActor
final class LegadoRuleTests: XCTestCase {
    func testCSSChainsAndIndexedAttributeExtraction() async throws {
        let html = #"<div class="book"><div class="bookname"><a href="/book/1">山海</a></div><span><a title="第一位作者">作者</a></span><span><a title="第二位作者">作者</a></span></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: ".book", fields: ["url": ".bookname@a@href", "author": "span[0]@a@title"])
        XCTAssertEqual(rows, [["url": "/book/1", "author": "第一位作者"]])
    }

    func testLegadoClassTagAndNegativeIndexSelectors() async throws {
        let html = #"<ul class="list"><li><a href="/first">首章</a><a href="/last">尾章</a></li><li><a href="/ignored">不应匹配</a></li></ul>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: "class.list@tag.li.0", fields: ["first": "tag.a.0@href", "last": "tag.a.-1@text"])
        XCTAssertEqual(rows, [["first": "/first", "last": "尾章"]])
    }

    func testBareTextAndHrefReadCurrentListElement() async throws {
        let html = #"<div class="list"><a href="/a">甲书</a><a href="/b">乙书</a></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: ".list a", fields: ["name": "text", "url": "href"])
        XCTAssertEqual(rows, [["name": "甲书", "url": "/a"], ["name": "乙书", "url": "/b"]])
    }

    func testRegexDeletionAndCaptureReplacement() async throws {
        let html = #"<span class="kind">分类：仙侠（123）</span>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: nil, fields: ["deletion": ".kind@text##分类：", "capture": ".kind@text##分类：(.+)（([0-9]+)）##$1 / $2"])
        XCTAssertEqual(rows.first?["deletion"], "仙侠（123）")
        XCTAssertEqual(rows.first?["capture"], "仙侠 / 123")
        XCTAssertEqual(try LegadoRule.replace("正文\n广告：不要保留\n结尾", using: "##广告：[^\\n]*\\n"), "正文\n结尾")
    }

    func testJSONPrefixListsFieldsAndReplacements() async throws {
        let data = Data(#"{"books":[{"name":"名称：山海","url":"/a","wordCount":120}]}"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: "@json:$.books[*]", fields: ["name": "@json:$.name##名称：", "url": "@json:$.url", "count": "@json:$.wordCount"])
        XCTAssertEqual(rows, [["name": "山海", "url": "/a", "count": "120"]])
    }

    func testHTMLReplacementRunsBeforeConversionToReadableText() async throws {
        let html = #"<div id="content"><p>第一段</p><p class="ad"><b>广告段落</b></p><p>第二段</p><script>window.untrustedExecuted=true;</script></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: nil, fields: ["content": #"#content@html##<p class="ad">[\s\S]*?</p>"#])
        XCTAssertEqual(rows.first?["content"], "<div id=\"content\"><p>第一段</p><p>第二段</p></div>")
    }

    func testUnsafeOrAmbiguousRulesAreRejectedExplicitly() throws {
        XCTAssertThrowsError(try LegadoRule.validate("@js:java.getString('content')"))
        XCTAssertThrowsError(try LegadoRule.validate("@xpath://div"))
        XCTAssertThrowsError(try LegadoRule.validate(".a&&.b@text"))
        XCTAssertThrowsError(try LegadoRule.validate("tag.a.-9223372036854775808@text"))
        XCTAssertThrowsError(try LegadoRule.validate(".name@text##["))
        XCTAssertThrowsError(try LegadoRule.validateList(".item@text"))
        XCTAssertThrowsError(try LegadoRule.validateList(".item##remove"))
    }

    func testStaticHeadersArePassedThroughSearchDetailCatalogAndChapterRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("header-tests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        var source = BookSource.example
        source.bookSourceUrl = "https://headers.fixture.invalid/"
        source.enabled = true
        source.rawFields["header"] = .string(#"{"User-Agent":"FixtureReader/1.0","Referer":"baseUrl"}"#)
        source.ruleContent["replaceRegex"] = "##广告：\\n"
        XCTAssertEqual(try source.validatedHeaders(), ["User-Agent": "FixtureReader/1.0", "Referer": "https://headers.fixture.invalid/"])
        try store.save(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = SourceEngine(session: session, store: store)
        let results = try await engine.search(source: source, query: "山海")
        let book = try await engine.loadBook(XCTUnwrap(results.first))
        let chapter = try XCTUnwrap(book.chapters.first)
        let content = try await engine.loadChapter(chapter, sourceID: source.id)
        XCTAssertEqual(content, "第一段\n第二段")
    }

    func testDynamicAndControlCharacterHeadersStayUnsupported() throws {
        XCTAssertThrowsError(try LegadoRule.validatedHeaders(["User-Agent": "@js:java.getWebViewUA()"] ))
        XCTAssertThrowsError(try LegadoRule.validatedHeaders(["Referer": "https://fixture.invalid/\r\nInjected: x"] ))
        XCTAssertThrowsError(try LegadoRule.validatedHeaders(["User-Agent": "one", "user-agent": "two"] ))
        XCTAssertThrowsError(try LegadoRule.validatedHeaders(["Cookie": "session=fixture"] ))
    }
}

private final class HeaderFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "headers.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let validHeaders = request.value(forHTTPHeaderField: "User-Agent") == "FixtureReader/1.0" && request.value(forHTTPHeaderField: "Referer") == "https://headers.fixture.invalid/"
        let text: String
        switch url.path {
        case "/search": text = #"{"books":[{"name":"山海","author":"合成作者","url":"/book/1","intro":"合成简介"}]}"#
        case "/book/1": text = #"{"tocUrl":"/toc/1"}"#
        case "/toc/1": text = #"{"chapters":[{"title":"第一章","url":"/chapter/1"}]}"#
        case "/chapter/1": text = #"{"content":"广告：\n第一段\n广告：\n第二段"}"#
        default: text = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: validHeaders ? 200 : 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
