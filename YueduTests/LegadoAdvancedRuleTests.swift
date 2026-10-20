import XCTest
import WebKit
@testable import Yuedu

/// Offline fixtures exercise rule semantics independently of third-party sites.
@MainActor
final class LegadoAdvancedRuleTests: XCTestCase {
    private let listHTML = "<ul><li>A</li><li>B</li><li>C</li><li>D</li><li>E</li></ul>"

    func testLegacyIndexListsInclusiveRangesAndExclusionPreserveOrder() async throws {
        let rows = try await SourceEngine().extract(Data(listHTML.utf8), listRule: nil, fields: [
            "legacy": "li.3:0:-1@text",
            "range": "li[1:3]@text",
            "reverse": "li[-1:0:2]@text",
            "union": "li[3,0:1,3]@text",
            "excluded": "li!0:-1@text",
            "excludedRange": "li[!1:3]@text"
        ])
        XCTAssertEqual(rows.first, ["legacy": "D\nA\nE", "range": "B\nC\nD", "reverse": "E\nC\nA", "union": "D\nA\nB", "excluded": "B\nC\nD", "excludedRange": "A\nE"])
    }

    func testJsoupPredicatesApplyAtTheCorrectAncestorAndSibling() async throws {
        let html = #"<div class="row"><span>作者：甲</span><a href="/a">甲书</a></div><div class="row"><span>作者：乙</span><a href="/b">乙书</a></div><dl><dt>作者</dt><dd>丙</dd><dt>分类</dt><dd>仙侠</dd></dl><meta property="og:novel:author" content="丁"><meta property="og:novel:category" content="历史">"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: nil, fields: [
            "ancestor": ".row:contains(甲) > a@href",
            "sibling": "@css:dt:containsOwn(作者) + dd@text",
            "regexAttribute": "[property~=author|category]@content",
            "matches": ".row:matches(作者：乙) a@href",
            "hasNot": ".row:has(a):not(:contains(甲))@a@text",
            "ownText": "text.作者：甲@text"
        ])
        XCTAssertEqual(rows.first, ["ancestor": "/a", "sibling": "丙", "regexAttribute": "丁\n历史", "matches": "/b", "hasNot": "乙书", "ownText": "作者：甲"])
    }

    func testCombinationsProtectQuotedSeparatorsAndInterleave() async throws {
        let html = #"<a data-token="x&amp;&amp;y">甲</a><a>乙</a><b>一</b><b>二</b><b>三</b>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: nil, fields: [
            "quoted": "a[data-token='x&&y']@text",
            "concat": "a.0@text&&b.0@text",
            "fallback": ".missing@text||a@text",
            "interleave": "a@text%%b@text"
        ])
        XCTAssertEqual(rows.first, ["quoted": "甲", "concat": "甲\n一", "fallback": "甲\n乙", "interleave": "甲\n一\n乙\n二"])
    }

    func testXPathIsScopedToEachSelectedRowAndSupportsPositionFunctions() async throws {
        let html = #"<div class="book"><a href="/a">甲书</a><p>简介甲</p><p>广告</p></div><div class="book"><a href="/b">乙书</a><p>简介乙</p><p>广告</p></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: "//div[@class='book']", fields: [
            "name": "//a/text()", "url": "//a/@href", "intro": "//p[position() < last()]/text()"
        ])
        XCTAssertEqual(rows, [["name": "甲书", "url": "/a", "intro": "简介甲"], ["name": "乙书", "url": "/b", "intro": "简介乙"]])
    }

    func testXPathRetainsTableFragmentsAsRows() async throws {
        let html = "<table><tr><td>甲</td><td>一</td></tr><tr><td>乙</td><td>二</td></tr></table>"
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: "//tr", fields: ["first": "//td[1]/text()", "last": "//td[last()]/text()"])
        XCTAssertEqual(rows, [["first": "甲", "last": "一"], ["first": "乙", "last": "二"]])
    }

    func testJSONPathRecursiveDescentFiltersAndNegativeSlices() async throws {
        let data = Data(#"{"groups":[{"books":[{"name":"Apple","price":3,"available":true},{"name":"Berry","price":8,"available":true},{"name":"Cedar","price":2,"available":false}]}]}"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: "$..books[?(@.price < 5 && @.available == true)]", fields: ["name": "$.name", "price": "$.price"])
        XCTAssertEqual(rows, [["name": "Apple", "price": "3"]])
        let scalars = try await SourceEngine().extract(data, listRule: nil, fields: [
            "recursive": "$..name", "negative": "$..books[-2:].name", "regex": "$..books[?(@.name =~ /APP/i)].name"
        ])
        XCTAssertEqual(scalars.first, ["recursive": "Apple\nBerry\nCedar", "negative": "Berry\nCedar", "regex": "Apple"])
    }

    func testJSONPathQuotedKeysUnionsAndLegacyInterpolation() async throws {
        let data = Data(#"{"book.name":"春日","status":1,"tags":["文学","随笔"],"ratings":[2,4,6]}"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: nil, fields: [
            "quoted": "$['book.name']", "union": "$.ratings[2,0]", "sum": "$.ratings.sum()", "legacy": "@json:连载中{$.status}已完结##连载中0|1已完结"
        ])
        XCTAssertEqual(rows.first, ["quoted": "春日", "union": "6\n2", "sum": "12", "legacy": "连载中"])
    }

    func testJSONContextRecognizesBarePathsAndURLInterpolation() async throws {
        let data = Data(#"{"data":{"books":[{"name":"春日","id":7,"volume":false},{"name":"分卷","id":8,"volume":true}]}}"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: "data.books[?(@.volume==false)]", fields: ["name": "name", "url": "/pc/book/{$.id}/catalog"])
        XCTAssertEqual(rows, [["name": "春日", "url": "/pc/book/7/catalog"]])
    }

    func testRegexReplacementAndFirstMatchExtractionAreDifferent() async throws {
        let data = Data("<div>ID=123; ID=456</div>".utf8)
        let rows = try await SourceEngine().extract(data, listRule: nil, fields: [
            "all": "div@text##ID=(\\d+)##编号$1", "first": "div@text##ID=(\\d+)##$1###", "missing": "div@text##NOTFOUND=(\\d+)##$1###", "deletion": "div@text##ID="
        ])
        XCTAssertEqual(rows.first, ["all": "编号123; 编号456", "first": "123", "missing": "", "deletion": "123; 456"])
    }

    func testRegexListCaptureGroupsCanBecomeFields() async throws {
        let data = Data(#"<a href="/a">甲</a><a href="/b">乙</a>"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: #":<a href="([^"]+)">([^<]+)</a>"#, fields: ["url": "$1", "name": "$2"])
        XCTAssertEqual(rows, [["url": "/a", "name": "甲"], ["url": "/b", "name": "乙"]])
    }

    func testPutUsesOriginalContextAndGetReturnsLiteralValue() async throws {
        let html = #"<div class="book"><a href="/detail">书名</a><span>作者甲</span></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: ".book", fields: [
            "saved": #"@put:{author:"span@text",url:"a@href"}作者：@get:{author}；地址：@get:{url}"#,
            "title": #"a@text@put:{extra:"span@text"}"#
        ])
        XCTAssertEqual(rows.first, ["saved": "作者：作者甲；地址：/detail", "title": "书名"])
    }

    func testNestedRuleTemplatesAndJavaScriptStagesKeepJSONTypes() async throws {
        let data = Data(#"{"books":[{"name":"春日","chapters":[{"title":"甲"},{"title":"乙"}]}]}"#.utf8)
        let rows = try await SourceEngine().extract(data, listRule: "$.books", fields: [
            "template": "名称：{{$.name}}，章节：{{2 + 1}}",
            "chain": "$.name<js>result + '手记'</js>",
            "jsonAfterJS": #"<js>JSON.stringify({value: '尾章'})</js>$.value"#
        ])
        XCTAssertEqual(rows.first, ["template": "名称：春日，章节：3", "chain": "春日手记", "jsonAfterJS": "尾章"])
    }

    func testJavaScriptStagesAllowRegexPostprocessingAndRegexOnlyStages() async throws {
        let rows = try await SourceEngine().extract(Data("<p>ad hello</p>".utf8), listRule: nil, fields: [
            "suffix": "p@text@js:result.toUpperCase()##AD ",
            "regexOnly": "p@text<js>##ad </js><js>##hello##世界</js>",
            "literal": #"@js:'a##b'.replace(/##/g, ':')##a##A"#,
            "first": #"@js:'ID=1 ID=2'##ID=(\d+)##$1###"#
        ])
        XCTAssertEqual(rows.first, ["suffix": "HELLO", "regexOnly": "世界", "literal": "A:b", "first": "1"])
    }

    func testJSoupBridgeSupportsSelectionMutationAndJavaCollectionMethods() async throws {
        let html = #"<div><p class="ad">广告</p><p>第一段 <b>重点</b></p><p>第二段</p></div>"#
        let rows = try await SourceEngine().extract(Data(html.utf8), listRule: nil, fields: [
            "result": #"@js:var doc = Packages.org.jsoup.Jsoup.parse(String(result)); doc.select('.ad').remove(); var paragraphs = doc.select('p'); paragraphs.size() + ':' + paragraphs.get(0).text() + '|' + paragraphs.get(1).text();"#
        ])
        XCTAssertEqual(rows.first?["result"], "2:第一段 重点|第二段")
    }

    func testJSoupCollectionFilteringDoesNotDeleteDOMAndRetainsNodeIdentity() async throws {
        let rows = try await SourceEngine().extract(Data("<div><p>A</p><p>B</p><p>C</p></div>".utf8), listRule: nil, fields: [
            "result": #"@js:var doc=Packages.org.jsoup.Jsoup.parse(String(result)); var ps=doc.select('p'); var same=ps.get(0)===ps.get(0); var parent=ps.get(0).parents().contains(doc.select('div').first()); ps.remove(1); ps.subList(0,1).clear(); [same,parent,ps.text(),doc.select('p').size(),doc.select('p').eachText().get(1)].join('|');"#
        ])
        XCTAssertEqual(rows.first?["result"], "true|true|C|3|B")
    }

    func testHTMLExtractionIsInertAndReadableConversionPreservesParagraphs() async throws {
        let result = try await runRuleFixture(#"""
        const html = '<div><p>第一段</p><p>第二段<br>第三行</p><script>globalThis.siteScriptRan=true</script><style>p{}</style></div>';
        const extracted = LegadoRules.extract(html, 'div@html', {}, 'string');
        const all = LegadoRules.extract(html, 'div@all', {}, 'string');
        return JSON.stringify({text:LegadoRules.htmlText(extracted), hasScript:extracted.includes('<script'), allHasScript:all.includes('<script'), executed:!!globalThis.siteScriptRan});
        """#)
        XCTAssertEqual(result["text"] as? String, "第一段\n第二段\n第三行")
        XCTAssertEqual(result["hasScript"] as? Bool, false)
        XCTAssertEqual(result["allHasScript"] as? Bool, true)
        XCTAssertEqual(result["executed"] as? Bool, false)
    }

    func testPlainTextContentKeepsBlankLinesAndDecodesEntities() async throws {
        let result = try await runRuleFixture(#"""
        return JSON.stringify({plain:LegadoRules.htmlText('第一段\n\n第二段'), entities:LegadoRules.htmlText('甲 &amp; 乙\n\n1 &lt; 2'), literal:LegadoRules.htmlText('第一段\n\n末尾 < 未闭合')});
        """#)
        XCTAssertEqual(result["plain"] as? String, "第一段\n\n第二段")
        XCTAssertEqual(result["entities"] as? String, "甲 & 乙\n\n1 < 2")
        XCTAssertEqual(result["literal"] as? String, "第一段\n\n末尾 < 未闭合")
    }

    func testInvalidIndicesAndRegexThrowInsteadOfTrappingOrReturningWrongData() async throws {
        let result = try await runRuleFixture(#"""
        const errors = [];
        for (const rule of ['li.999999999999999999999@text','li@text##[','@json:$.items[?(unknown())]']) {
          try { LegadoRules.extract(rule.includes('@json:')?'{"items":[{}]}':'<li>甲</li>',rule,{},'string'); errors.push(false); }
          catch (error) { errors.push(error.message.startsWith('规则解析：')); }
        }
        return JSON.stringify({errors});
        """#)
        XCTAssertEqual(result["errors"] as? [Bool], [true, true, true])
    }

    private func runRuleFixture(_ fixture: String) async throws -> [String: Any] {
        let bundle = Bundle.main
        let url = try XCTUnwrap(bundle.url(forResource: "rules", withExtension: "js", subdirectory: "Legado") ?? bundle.url(forResource: "rules", withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let output = try await webView.callAsyncJavaScript(script + "\n" + fixture, arguments: [:], in: nil, contentWorld: .page)
        let text = try XCTUnwrap(output as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
