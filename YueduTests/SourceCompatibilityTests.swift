import XCTest
@testable import Yuedu

@MainActor
final class SourceCompatibilityTests: XCTestCase {
    func testScriptsAndUnrecognizedMetadataSurviveImportExportAndReopening() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        var object = compatibleSource(name: "合成脚本书源", url: "合成书源标识")
        object["searchUrl"] = "<js>\nconst endpoint = source.getVariable();\nendpoint + '/search?q=' + key\n</js>"
        object["header"] = "@js:JSON.stringify({'User-Agent': java.getWebViewUA()})"
        object["loginUrl"] = "https://fixture.invalid/login"
        object["loginUi"] = #"[{"name":"账号","type":"text","action":""}]"#
        object["loginCheckJs"] = "if (result) source.setVariable(result);"
        object["jsLib"] = "function helper(value) { return value; }"
        object["exploreUrl"] = "<js>helper('discovery')</js>"
        object["ruleExplore"] = ["bookList": "$.items", "name": "$.title"]
        object["bookSourceComment"] = "用于验证原始字段保留的合成数据。\n第二行说明。"
        object["enabledCookieJar"] = true
        object["lastUpdateTime"] = 1_789_228_016_734 as Int64
        object["futureMetadata"] = ["null": NSNull(), "flags": [true, false], "values": [1, 1.5, -3], "nested": ["key": "值"]] as [String: Any]

        XCTAssertEqual(try store.importData(encode(object)), 1)
        let imported = try XCTUnwrap(store.sources.first)
        XCTAssertEqual(imported.bookSourceUrl, "合成书源标识")
        XCTAssertTrue(imported.enabled)
        XCTAssertTrue(imported.isCompatible)
        XCTAssertTrue(imported.compatibilityIssues.isEmpty)

        let reopened = SourceStore(directory: directory)
        XCTAssertNil(reopened.persistenceError)
        let exported = try XCTUnwrap((JSONSerialization.jsonObject(with: reopened.exportData()) as? [[String: Any]])?.first)
        try assertPreservedFields(object, in: exported)
    }

    func testMixedImportKeepsScriptedTextSourcesExcludesAudioAndReportsInvalidRows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let ready = compatibleSource(name: "可用规则", url: "https://ready.fixture.invalid")
        var scripted = compatibleSource(name: "脚本规则", url: "脚本标识")
        scripted["ruleContent"] = ["content": "@js:java.getString('body')"]
        var audio = compatibleSource(name: "有声书源", url: "https://audio.fixture.invalid")
        audio["bookSourceType"] = 1
        var invalid = compatibleSource(name: "", url: "https://invalid.fixture.invalid")
        invalid["bookSourceName"] = "  "

        let report = try await store.importDataAsync(encode([ready, scripted, audio, invalid]))
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertEqual(report.readyCount, 2)
        XCTAssertEqual(report.disabledCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.excludedCount, 1)
        XCTAssertEqual(report.issues.filter { $0.kind == .excluded }.count, 1)
        XCTAssertEqual(report.issues.filter { $0.kind == .invalid }.count, 1)
        XCTAssertEqual(store.sources.map(\.bookSourceName), ["可用规则", "脚本规则"])
        XCTAssertEqual(store.sources.map(\.enabled), [true, true])
        XCTAssertEqual(store.sources.map(\.isCompatible), [true, true])
        XCTAssertEqual(SourceStore(directory: directory).sources, store.sources)
    }

    func testStrictDecodeAcceptsScriptedOpaqueIdentifiersButRejectsMissingIdentity() throws {
        var unsupported = compatibleSource(name: "保留脚本", url: "非网址唯一标识")
        unsupported["searchUrl"] = "@js:java.getString('url')"
        let source = try XCTUnwrap(SourceStore.decode(encode(unsupported)).first)
        XCTAssertEqual(source.bookSourceUrl, "非网址唯一标识")
        XCTAssertTrue(source.enabled)
        XCTAssertTrue(source.isCompatible)

        for missingField in ["bookSourceName", "bookSourceUrl"] {
            var malformed = unsupported
            malformed.removeValue(forKey: missingField)
            XCTAssertThrowsError(try SourceStore.decode(encode(malformed)), "Missing \(missingField) must remain a structural error.")
        }
    }

    func testScalarAndStructuredRuleValuesAreRetainedWithoutAbortingCollection() throws {
        var unusual = compatibleSource(name: "混合字段类型", url: "https://mixed.fixture.invalid")
        unusual["ruleSearch"] = [
            "bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url",
            "wordCount": 12, "futureFlag": true, "intro": NSNull(),
            "futureObject": ["selector": ".name", "enabled": false],
            "futureArray": ["$.title", 3]
        ] as [String: Any]
        unusual["futureNull"] = NSNull()
        let sources = try SourceStore.decode(encode([compatibleSource(), unusual]))
        XCTAssertEqual(sources.count, 2)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(sources[1])) as? [String: Any])
        try assertJSONEqual(unusual["ruleSearch"], exported["ruleSearch"])
        XCTAssertTrue(exported["futureNull"] is NSNull)
    }

    func testMalformedExecutionRuleCannotBeEnabledAccidentally() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        var object = compatibleSource()
        object["ruleContent"] = ["content": ["selector": "#content"]]
        try store.importData(encode(object))
        let id = try XCTUnwrap(store.sources.first?.id)
        XCTAssertThrowsError(try store.setEnabled(id: id, enabled: true))
        XCTAssertEqual(store.sources.first?.enabled, false)
        XCTAssertEqual(SourceStore(directory: directory).sources.first?.enabled, false)
    }

    func testExactSourceIdentifiersDoNotCollapseDistinctSameHostEntries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let first = compatibleSource(name: "版本一", url: "https://fixture.invalid")
        let second = compatibleSource(name: "版本二", url: "https://fixture.invalid/")
        let third = compatibleSource(name: "分组版本", url: "https://fixture.invalid#variant")
        XCTAssertEqual(try store.importData(encode([first, second, third])), 3)
        XCTAssertEqual(store.sources.count, 3)
        XCTAssertEqual(Set(store.sources.map(\.id)).count, 3)
        XCTAssertEqual(store.sources.map(\.bookSourceUrl), ["https://fixture.invalid", "https://fixture.invalid/", "https://fixture.invalid#variant"])
    }

    func testUpdatePreservesIdentityAndReplacesRawMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        var object = compatibleSource()
        object["bookSourceComment"] = "第一版说明"
        object["jsLib"] = "function version() { return 1; }"
        try store.importData(encode(object))
        let id = try XCTUnwrap(store.sources.first?.id)
        object["bookSourceComment"] = "第二版说明"
        object["jsLib"] = "function version() { return 2; }"
        try store.importData(encode(object))
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertEqual(store.sources.first?.id, id)
        let exported = try XCTUnwrap((JSONSerialization.jsonObject(with: store.exportData()) as? [[String: Any]])?.first)
        XCTAssertEqual(exported["bookSourceComment"] as? String, "第二版说明")
        XCTAssertEqual(exported["jsLib"] as? String, "function version() { return 2; }")
    }

    func testMalformedRowsDoNotMaskSupportedSourcesInAsyncImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let mixed: [Any] = [NSNull(), 7, "not a source", compatibleSource()]
        let report = try await store.importDataAsync(encode(mixed))
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.readyCount, 1)
        XCTAssertEqual(report.skippedCount, 3)
        XCTAssertEqual(store.sources.count, 1)
    }

    func testRemovingAnOptionalTypedRulePersistsWithoutResurrectingRawValue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        var object = compatibleSource()
        object["ruleBookInfo"] = ["tocUrl": "$.tocUrl", "intro": "$.intro", "futureMetadata": ["version": 1]] as [String: Any]
        let original = try XCTUnwrap(SourceStore.decode(encode(object)).first)
        var edited = original
        edited.ruleBookInfo.removeValue(forKey: "intro")
        XCTAssertNotEqual(edited, original, "Deleting a rule changes the model's persistent content.")

        try store.save(edited)
        let reopened = SourceStore(directory: directory)
        XCTAssertNil(reopened.sources.first?.ruleBookInfo["intro"], "The deleted rule must not return after reopening.")
        let exported = try XCTUnwrap((JSONSerialization.jsonObject(with: reopened.exportData()) as? [[String: Any]])?.first)
        let rules = try XCTUnwrap(exported["ruleBookInfo"] as? [String: Any])
        XCTAssertNil(rules["intro"])
        XCTAssertEqual(rules["tocUrl"] as? String, "$.tocUrl")
        try assertJSONEqual(["version": 1], rules["futureMetadata"])
    }

    func testMixedJSONAndCSSRulesAreRetainedForTheLegadoRuntime() throws {
        var search = compatibleSource(name: "搜索混用")
        search["ruleSearch"] = ["bookList": "$.books[*]", "name": ".title@text", "bookUrl": "$.url"]
        var info = compatibleSource(name: "详情混用")
        info["ruleBookInfo"] = ["name": "$.name", "tocUrl": "a@href"]
        var toc = compatibleSource(name: "目录混用")
        toc["ruleToc"] = ["chapterList": ".chapters li", "chapterName": "$.name", "chapterUrl": "a@href"]
        for object in [search, info, toc] {
            let source = try XCTUnwrap(SourceStore.decode(encode(object)).first)
            XCTAssertTrue(source.isCompatible, source.bookSourceName)
            XCTAssertTrue(source.enabled, source.bookSourceName)
            XCTAssertTrue(source.compatibilityIssues.isEmpty, source.bookSourceName)
        }
    }

    func testStructuredValueForAnExecutedOptionalRuleIsReportedInsteadOfIgnored() throws {
        var object = compatibleSource()
        object["ruleBookInfo"] = ["tocUrl": ["selector": "a", "attribute": "href"]]
        let source = try XCTUnwrap(SourceStore.decode(encode(object)).first)
        XCTAssertFalse(source.isCompatible, "A present but unsupported tocUrl must not silently fall back to the book URL.")
        XCTAssertFalse(source.enabled)
        XCTAssertTrue(source.compatibilityIssues.contains(where: { $0.contains("tocUrl") }))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(source)) as? [String: Any])
        try assertJSONEqual(object["ruleBookInfo"], exported["ruleBookInfo"])
    }

    func testJavaScriptPOSTXPathJSONPathPaginationAndLoginFieldsDoNotDisableTextSources() throws {
        var object = compatibleSource(name: "完整文字规则", url: "不依赖基础网址的聚合标识")
        object["searchUrl"] = #"https://fixture.invalid/search,{"method":"POST","body":"q={{key}}&page={{page}}","charset":"GBK","headers":{"Referer":"https://fixture.invalid/"}}"#
        object["ruleSearch"] = ["bookList": "//div[@class='book']", "name": "./a/text()", "bookUrl": "./a/@href"]
        object["ruleBookInfo"] = ["init": "<js>result</js>", "tocUrl": "$..catalog[?(@.enabled == true)].url"]
        object["ruleToc"] = ["chapterList": "@json:$.chapters[*]", "chapterName": "$.name", "chapterUrl": "$.url", "nextTocUrl": "$.next"]
        object["ruleContent"] = ["content": "<js>java.getString('#content@html')</js>", "nextContentUrl": "a.next@href", "webJs": "document.querySelector('#content').textContent"]
        object["jsLib"] = "function helper(value) { return value; }"
        object["header"] = "@js:JSON.stringify({'User-Agent':java.getWebViewUA()})"
        object["loginUrl"] = "https://fixture.invalid/login"
        object["loginCheckJs"] = "result"
        object["concurrentRate"] = "3/1000"
        let source = try XCTUnwrap(SourceStore.decode(encode(object)).first)
        XCTAssertTrue(source.enabled)
        XCTAssertTrue(source.isCompatible)
        XCTAssertNoThrow(try source.validate())
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: SourceStore.encode(source)) as? [String: Any])
        try assertPreservedFields(object, in: exported)
    }

    func testEveryNonTextTypeIsExcludedByStrictAndAsynchronousImport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let items = [1, 2, 3, 4].map { type -> [String: Any] in
            var item = compatibleSource(name: "非文字类型 \(type)", url: "https://type-\(type).fixture.invalid")
            item["bookSourceType"] = type
            return item
        }
        let data = try encode(items)
        XCTAssertTrue(try SourceStore.decode(data).isEmpty)
        let report = try await store.importDataAsync(data)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(report.excludedCount, 4)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertTrue(store.sources.isEmpty)
    }

    func testOptionalProvidedCollectionImports342TextSourcesAndPreservesEveryRawField() async throws {
        // Local opt-in corpus: never bundled into the app/test target and never executed.
        // CI may set an absolute YUEDU_SOURCE_COLLECTION_PATH; absent corpus is a skip.
        let path = ProcessInfo.processInfo.environment["YUEDU_SOURCE_COLLECTION_PATH"] ?? "/Users/mac/Desktop/yuedu/build/SourceImportInvestigation/collection.json"
        guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path) else { throw XCTSkip("The optional user-provided collection is not available at an absolute local path.") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let originals = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(originals.count, 391)
        let textSources = originals.filter { ($0["bookSourceType"] as? Int ?? 0) == 0 }
        XCTAssertEqual(textSources.count, 342)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let report = try await store.importDataAsync(data)
        XCTAssertEqual(report.importedCount, 342)
        XCTAssertEqual(report.readyCount, 342)
        XCTAssertEqual(report.excludedCount, 49)
        XCTAssertEqual(report.disabledCount, 0)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertEqual(store.sources.count, 342)
        XCTAssertTrue(store.sources.allSatisfy { $0.isTextSource && $0.enabled })
        let reopened = SourceStore(directory: directory)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.sources, store.sources)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: reopened.exportData()) as? [[String: Any]])
        let byIdentifier = Dictionary(uniqueKeysWithValues: exported.compactMap { item -> (String, [String: Any])? in
            guard let id = item["bookSourceUrl"] as? String else { return nil }; return (id, item)
        })
        for original in textSources {
            let identifier = try XCTUnwrap(original["bookSourceUrl"] as? String)
            let preserved = try XCTUnwrap(byIdentifier[identifier])
            try assertPreservedFields(original, in: preserved)
            try assertJSONEqual(original["enabled"], preserved["enabled"])
        }
    }

    private func compatibleSource(name: String = "合成基础书源", url: String = "https://fixture.invalid") -> [String: Any] {
        [
            "bookSourceName": name, "bookSourceUrl": url, "bookSourceGroup": "回归测试",
            "bookSourceType": 0, "enabled": true, "searchUrl": "/search?q={{key}}&page={{page}}",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.name", "bookUrl": "$.url"],
            "ruleBookInfo": ["tocUrl": "$.tocUrl"],
            "ruleToc": ["chapterList": "$.chapters[*]", "chapterName": "$.title", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.content"]
        ]
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compatibility-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertPreservedFields(_ original: [String: Any], in exported: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        for (key, value) in original where key != "id" && key != "enabled" {
            XCTAssertNotNil(exported[key], "Lost field: \(key)", file: file, line: line)
            try assertJSONEqual(value, exported[key], file: file, line: line)
        }
    }

    private func assertJSONEqual(_ expected: Any?, _ actual: Any?, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try XCTUnwrap(expected, file: file, line: line)
        let actual = try XCTUnwrap(actual, file: file, line: line)
        // Canonical JSON distinguishes booleans from integers, unlike NSNumber equality.
        XCTAssertEqual(try encode([expected]), try encode([actual]), file: file, line: line)
    }
}
