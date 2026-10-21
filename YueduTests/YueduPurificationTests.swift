import XCTest
import UIKit
@testable import Yuedu

final class YueduPurificationTests: XCTestCase {
    private func clean(_ text: String, _ rules: [YueduPurificationRule], title: String = "第一章 初见",
                       bookID: UUID? = nil, sourceID: UUID? = nil) throws -> YueduPurificationResult {
        try YueduTextPurifier.apply(text, chapterTitle: title, bookID: bookID, sourceID: sourceID,
                                   settings: YueduPurificationSettings(rules: rules))
    }

    func testLiteralReplacementPreservesDollarBackslashAndUnicode() throws {
        let rule = YueduPurificationRule(name: "字面替换", pattern: "[广告]", replacement: #"$1\正文"#)
        let result = try clean("📚[广告] 汉字\n[广告]结尾", [rule])
        XCTAssertEqual(result.text, #"📚$1\正文 汉字"# + "\n" + #"$1\正文结尾"#)
        XCTAssertEqual(result.hits[rule.id], 2)
    }

    func testRegexCapturesAndMultilineRemoval() throws {
        let ad = YueduPurificationRule(name: "指定广告行", kind: .regex, pattern: #"(?m)^推广：[^\n]*\n?"#)
        let rename = YueduPurificationRule(name: "捕获组", kind: .regex, pattern: "人物：(.*)", replacement: "主角：$1")
        let result = try clean("推广：测试链接\n人物：小林\n正文里提到了推广：这个词。", [ad, rename])
        XCTAssertEqual(result.text, "主角：小林\n正文里提到了推广：这个词。")
        XCTAssertEqual(result.hits[ad.id], 1)
    }

    func testRulesRunInUserOrderAndOnlyInTheirScope() throws {
        let bookID = UUID()
        let sourceID = UUID()
        let first = YueduPurificationRule(name: "本书", pattern: "甲", replacement: "乙", scope: .book, targetID: bookID)
        let second = YueduPurificationRule(name: "书源", pattern: "乙", replacement: "丙", scope: .source, targetID: sourceID)
        XCTAssertEqual(try clean("甲", [first, second], bookID: bookID, sourceID: sourceID).text, "丙")
        XCTAssertEqual(try clean("甲", [second, first], bookID: bookID, sourceID: sourceID).text, "乙")
        XCTAssertEqual(try clean("甲", [first, second], bookID: UUID(), sourceID: sourceID).text, "甲")
    }

    func testChapterTitleOnlyRemovesExactLeadingHeading() throws {
        let rule = YueduPurificationRule(name: "重复标题", kind: .chapterTitle)
        XCTAssertEqual(try clean("  第一章 初见\n正文\n第一章 初见", [rule]).text, "正文\n第一章 初见")
        XCTAssertEqual(try clean("第一章 初见以后\n正文", [rule]).text, "第一章 初见以后\n正文")
        XCTAssertEqual(try clean("第一章 [初见]\r\n正文", [rule], title: "第一章 [初见]").text, "正文")
    }

    func testPresetsKeepParagraphsAndDoNotGuessAdvertising() throws {
        let text = "第一章 初见\n正文\u{200B}\n\n\n\n人物说：请记住本站这个名字。"
        let result = try clean(text, YueduPurificationRule.presets)
        XCTAssertEqual(result.text, "正文\n\n人物说：请记住本站这个名字。")
    }

    func testEmptyOutputFallsBackToOriginalAndReportsIt() throws {
        let result = try clean("正文\n不能丢失", [YueduPurificationRule(name: "全部删除", kind: .regex, pattern: "(?s).+")])
        XCTAssertEqual(result.text, "正文\n不能丢失")
        XCTAssertTrue(result.restoredOriginal)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testGlobalBookAndRuleSwitchesRestoreOriginal() throws {
        let bookID = UUID()
        let rule = YueduPurificationRule(name: "测试", pattern: "原文", replacement: "净化")
        var settings = YueduPurificationSettings(rules: [rule])
        settings.enabled = false
        XCTAssertEqual(try YueduTextPurifier.apply("原文", chapterTitle: "", bookID: bookID, sourceID: nil, settings: settings).text, "原文")
        settings.enabled = true
        settings.originalBookIDs.insert(bookID)
        XCTAssertEqual(try YueduTextPurifier.apply("原文", chapterTitle: "", bookID: bookID, sourceID: nil, settings: settings).text, "原文")
        settings.originalBookIDs.removeAll()
        settings.rules[0].enabled = false
        XCTAssertEqual(try YueduTextPurifier.apply("原文", chapterTitle: "", bookID: bookID, sourceID: nil, settings: settings).text, "原文")
    }

    func testPathologicalRegexStopsWithoutPublishingPartialReplacement() throws {
        let rule = YueduPurificationRule(name: "回溯测试", kind: .regex, pattern: "(a+)+$")
        let text = String(repeating: "a", count: 30_000) + "!"
        let start = ProcessInfo.processInfo.systemUptime
        let result = try YueduTextPurifier.apply(text, chapterTitle: "", bookID: nil, sourceID: nil,
                                               settings: YueduPurificationSettings(rules: [rule]), budget: 0.02)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testInvalidAndExpandingRulesLeaveOriginalUntouched() throws {
        let invalid = YueduPurificationRule(name: "错误正则", kind: .regex, pattern: "[")
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(try clean("原文", [invalid]).text, "原文")
        let expansion = YueduPurificationRule(name: "过度增长", pattern: "a", replacement: String(repeating: "b", count: 4_000))
        let text = String(repeating: "a", count: 3_000)
        let result = try clean(text, [expansion])
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testCancelledProcessingDoesNotReturnAResult() async throws {
        let rule = YueduPurificationRule(name: "取消测试", kind: .regex, pattern: "(a+)+$")
        let task = Task {
            try await YueduTextPurifier.process(String(repeating: "a", count: 30_000) + "!", chapterTitle: "",
                                               bookID: nil, sourceID: nil, settings: YueduPurificationSettings(rules: [rule]))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled purification must not publish a result")
        } catch is CancellationError { }
    }

    @MainActor
    func testStorePersistsScopeOrderAndTogglesAndRejectsInvalidBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = YueduPurificationStore(directory: directory)
        let bookID = UUID()
        let first = YueduPurificationRule(name: "一", pattern: "原", scope: .book, targetID: bookID, targetName: "示例书")
        let second = YueduPurificationRule(name: "二", pattern: "文")
        try store.save(first)
        try store.save(second)
        try store.update {
            $0.rules.reverse()
            $0.enabled = false
            $0.originalBookIDs.insert(bookID)
        }
        let saved = store.settings
        XCTAssertThrowsError(try store.update { $0.rules[0].pattern = "" })
        XCTAssertEqual(store.settings, saved)
        XCTAssertEqual(YueduPurificationStore(directory: directory).settings, saved)
        XCTAssertEqual(saved.rules.map(\.id), [second.id, first.id])
    }

    @MainActor
    func testImportIsAtomicDeduplicatedDisabledAndPreservesScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = YueduPurificationStore(directory: directory)
        let rule = YueduPurificationRule(name: "本书规则", pattern: "广告", scope: .book, targetID: UUID())
        let data = try JSONEncoder().encode(YueduPurificationStore.Export(rules: [rule]))
        XCTAssertEqual(try store.importData(data), 1)
        XCTAssertFalse(store.settings.rules[0].enabled)
        XCTAssertEqual(store.settings.rules[0].targetID, rule.targetID)
        XCTAssertEqual(try store.importData(data), 0)
        var invalid = rule
        invalid.kind = .regex
        invalid.pattern = "["
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(YueduPurificationStore.Export(rules: [rule, invalid]))))
        XCTAssertEqual(store.settings.rules.count, 1)
        let exported = try JSONDecoder().decode(YueduPurificationStore.Export.self, from: store.exportData())
        XCTAssertEqual(exported.rules, store.settings.rules)
    }

    @MainActor
    func testWriteFailureDoesNotPublishSettings() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("block directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = YueduPurificationStore(directory: path)
        XCTAssertThrowsError(try store.save(YueduPurificationRule(name: "测试", pattern: "广告")))
        XCTAssertTrue(store.settings.rules.isEmpty)
    }

    @MainActor
    func testReaderReprocessesCachedOriginalAndKeepsBookmarkAndChapter() async throws {
        let library = LibraryStore.shared
        let store = YueduPurificationStore.shared
        let oldSettings = store.settings
        let text = "推广：测试广告\n" + String(repeating: "正文应始终保留。\n", count: 80)
        let book = library.add(Book(title: UUID().uuidString, author: "测试", summary: "", category: "", coverColor: "517A65", coverSymbol: "book",
                                    chapters: [BookChapter(title: "第一章", content: text)], sourceName: "本地"))
        defer {
            try? store.update { $0 = oldSettings }
            library.remove(id: book.id)
        }
        library.addBookmark(bookID: book.id, chapterIndex: 0, scrollFraction: 0.3, title: "保留书签")
        library.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0.3)
        let rule = YueduPurificationRule(name: "本书广告", pattern: "推广：测试广告\n", scope: .book, targetID: book.id)
        try store.update { $0 = YueduPurificationSettings(rules: [rule]) }
        let reader = ReaderViewController(bookID: book.id)
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.view.layoutIfNeeded()
        func body(_ view: UIView) -> UILabel? {
            if view.accessibilityIdentifier == "reader.text" { return view as? UILabel }
            return view.subviews.lazy.compactMap { body($0) }.first
        }
        let label = try XCTUnwrap(body(reader.view))
        for _ in 0..<100 {
            if label.text?.contains("正文应始终保留") == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(label.text?.contains("测试广告") ?? true)
        XCTAssertEqual(library.book(id: book.id)?.chapters[0].content, text)
        XCTAssertEqual(library.book(id: book.id)?.progress.chapterIndex, 0)
        XCTAssertEqual(library.book(id: book.id)?.progress.scrollFraction ?? -1, 0.3, accuracy: 0.01)
        XCTAssertEqual(library.bookmarks.first { $0.bookID == book.id }?.scrollFraction, 0.3)
        try store.update { $0.originalBookIDs.insert(book.id) }
        XCTAssertTrue(label.text?.contains("测试广告") == true)
        XCTAssertEqual(library.book(id: book.id)?.chapters[0].content, text)
        XCTAssertEqual(library.book(id: book.id)?.progress.scrollFraction ?? -1, 0.3, accuracy: 0.01)
        reader.viewDidAppear(false)
        reader.viewWillDisappear(false)
        library.updateProgress(bookID: book.id, chapterIndex: 0, scrollFraction: 0.65)
        try store.update { $0.enabled = false }
        XCTAssertEqual(library.book(id: book.id)?.progress.scrollFraction ?? -1, 0.65, accuracy: 0.01,
                       "An offscreen reader must not replace newer progress when rules change")
    }
}
