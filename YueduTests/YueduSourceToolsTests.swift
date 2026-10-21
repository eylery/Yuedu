import XCTest
@testable import Yuedu

@MainActor
final class YueduSourceToolsTests: XCTestCase {
    private var directory: URL!
    private var store: SourceStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SourceStore(directory: directory)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func source(_ name: String, group: String = "网文") -> BookSource {
        var source = BookSource.example
        source.id = UUID()
        source.bookSourceName = name
        source.bookSourceUrl = "https://fixture.invalid/\(source.id)"
        source.bookSourceGroup = group
        source.enabled = true
        return source
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("检测状态等待超时", file: file, line: line)
    }

    func testBatchGroupDiscoveryAndExportPreserveRulesAndIdentity() throws {
        var first = source("甲")
        first.rawFields["futureField"] = .object(["keep": .integer(42)])
        first.rawFields["exploreUrl"] = .string("热门::/search")
        let second = source("乙")
        try store.save(first)
        try store.save(second)
        try store.setGroup(ids: [first.id], name: " 常用 ")
        try store.manage([first.id]) { $0.enabled = false; $0.rawFields["enabledExplore"] = .bool(false) }
        let restored = SourceStore(directory: directory)
        XCTAssertEqual(restored.source(id: first.id)?.bookSourceGroup, "常用")
        XCTAssertEqual(restored.source(id: first.id)?.ruleSearch, first.ruleSearch)
        XCTAssertEqual(restored.source(id: first.id)?.rawFields["futureField"], first.rawFields["futureField"])
        XCTAssertEqual(restored.source(id: first.id)?.rawFields["enabledExplore"], .bool(false))
        XCTAssertEqual(restored.source(id: second.id), second)
        let exported = try SourceStore.decode(store.exportData(ids: [first.id]))
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.id, first.id)
        XCTAssertEqual(exported.first?.enabled, false)
    }

    func testInvalidBatchEnableIsAtomic() throws {
        var good = source("正常")
        good.enabled = false
        var malformed = source("错误配置")
        malformed.rawFields["ruleContent"] = .object(["content": .array([.string("invalid")])])
        malformed.ruleContent = [:]
        try store.save(good)
        try store.save(malformed)
        let before = store.sources
        XCTAssertThrowsError(try store.manage([good.id, malformed.id]) { $0.enabled = true })
        XCTAssertEqual(store.sources, before)
        XCTAssertEqual(SourceStore(directory: directory).sources, before)
    }

    func testFailedDiskWriteDoesNotPublishBatchOrDelete() throws {
        let first = source("甲")
        try store.save(first)
        let file = directory.appendingPathComponent("sources.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.manage([first.id]) { $0.enabled = false })
        XCTAssertThrowsError(try store.remove(ids: [first.id]))
        XCTAssertEqual(store.sources, [first])
    }

    func testGroupValidationAndRemovalTouchOnlySelection() throws {
        let first = source("甲")
        let second = source("乙")
        try store.save(first)
        try store.save(second)
        XCTAssertThrowsError(try store.setGroup(ids: [first.id], name: "一,二"))
        XCTAssertThrowsError(try store.setGroup(ids: [first.id], name: String(repeating: "长", count: 41)))
        try store.setGroup(ids: [first.id], name: "")
        XCTAssertEqual(store.source(id: first.id)?.bookSourceGroup, "")
        try store.remove(ids: [first.id])
        XCTAssertEqual(store.sources, [second])
        XCTAssertEqual(SourceStore(directory: directory).sources, [second])
    }

    func testSearchGroupAndStateFiltering() throws {
        let first = source("常用小说", group: "网文,常用")
        var second = source("备用小说", group: "")
        second.enabled = false
        second.rawFields["exploreUrl"] = .string("热门::/books")
        try store.save(first)
        try store.save(second)
        let checker = YueduSourceChecker(store: store, directory: directory)
        XCTAssertEqual(checker.filtered(query: "常用", group: "网文", filter: .enabled, sort: .name).map(\.id), [first.id])
        XCTAssertEqual(checker.filtered(query: "fixture.invalid", group: "", filter: .discovery, sort: .imported).map(\.id), [second.id])
        XCTAssertEqual(checker.filtered(query: "", group: nil, filter: .unchecked, sort: .imported).count, 2)
    }

    func testChecksPersistOutcomesWithoutChangingSourcesAndInvalidateOnEdit() async throws {
        let good = source("正常")
        let bad = source("失败")
        var empty = source("无结果")
        empty.enabled = false
        for source in [good, bad, empty] { try store.save(source) }
        let before = store.sources
        let checker = YueduSourceChecker(store: store, directory: directory) { source, _, _ in
            if source.id == bad.id { throw SourceError.network("连接失败") }
            if source.id == empty.id { return (.empty, "搜索", "换个关键词试试") }
            return (.passed, "首章正文", "检测成功")
        }
        try checker.start(ids: Set(before.map(\.id)), keyword: "小说", mode: .reading)
        try await eventually { !checker.isRunning }
        XCTAssertEqual(store.sources, before)
        XCTAssertEqual(checker.result(for: good)?.outcome, .passed)
        XCTAssertEqual(checker.result(for: bad)?.outcome, .failed)
        XCTAssertEqual(checker.result(for: empty)?.outcome, .empty)
        XCTAssertEqual(checker.filtered(query: "", group: nil, filter: .failed, sort: .speed).map(\.id), [bad.id])
        let restored = YueduSourceChecker(store: store, directory: directory)
        XCTAssertEqual(restored.result(for: good), checker.result(for: good))
        try store.setEnabled(id: bad.id, enabled: false)
        XCTAssertEqual(restored.result(for: store.source(id: bad.id)!)?.outcome, .failed)
        var edited = good
        edited.searchUrl = "/new-search"
        try store.save(edited)
        XCTAssertNil(restored.result(for: edited))
    }

    func testCancellationDiscardsLateResultAndDoesNotStartNextSource() async throws {
        let first = source("一")
        let second = source("二")
        try store.save(first)
        try store.save(second)
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let checker = YueduSourceChecker(store: store, directory: directory) { _, _, _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return (.passed, "搜索", "完成")
        }
        try checker.start(ids: [first.id, second.id], keyword: "测试", mode: .search)
        XCTAssertThrowsError(try checker.start(ids: [first.id], keyword: "测试", mode: .search))
        try await eventually { continuation != nil }
        checker.cancel()
        continuation?.resume()
        try await eventually { !checker.isRunning }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(checker.result(for: first))
        XCTAssertNil(checker.result(for: second))
    }

    func testEditingDuringCheckDiscardsStaleResult() async throws {
        var first = source("一")
        try store.save(first)
        var continuation: CheckedContinuation<Void, Never>?
        let checker = YueduSourceChecker(store: store, directory: directory) { _, _, _ in
            await withCheckedContinuation { continuation = $0 }
            return (.passed, "搜索", "旧结果")
        }
        try checker.start(ids: [first.id], keyword: "测试", mode: .search)
        try await eventually { continuation != nil }
        first.searchUrl = "/changed"
        try store.save(first)
        continuation?.resume()
        try await eventually { !checker.isRunning }
        XCTAssertNil(checker.result(for: first))
        XCTAssertTrue(checker.message.contains("配置变动已跳过"))
    }

    func testDetectionStorageFailureAndKeywordValidation() async throws {
        let source = source("一")
        try store.save(source)
        let checker = YueduSourceChecker(store: store, directory: directory) { _, _, _ in (.passed, "搜索", "成功") }
        XCTAssertThrowsError(try checker.start(ids: [source.id], keyword: "  ", mode: .search))
        XCTAssertThrowsError(try checker.start(ids: [], keyword: "书名", mode: .search))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("source-checks.json"), withIntermediateDirectories: false)
        try checker.start(ids: [source.id], keyword: "书名", mode: .search)
        try await eventually { !checker.isRunning }
        XCTAssertTrue(checker.message.contains("保存失败"))
        XCTAssertNil(checker.result(for: source))
        XCTAssertEqual(store.sources, [source])
    }
}
