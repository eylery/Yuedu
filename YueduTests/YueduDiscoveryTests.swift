import XCTest
@testable import Yuedu

@MainActor
final class YueduDiscoveryTests: XCTestCase {
    private func source(_ name: String, group: String = "小说,测试") -> BookSource {
        var source = BookSource.example
        source.id = UUID()
        source.bookSourceName = name
        source.bookSourceUrl = "https://fixture.invalid/\(source.id)"
        source.bookSourceGroup = group
        source.enabled = true
        source.rawFields["exploreUrl"] = .string("热门::/books")
        return source
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected discovery state did not arrive", file: file, line: line)
    }

    func testEligibilityGroupAndNameFilteringDoNotExecuteRules() {
        var calls = 0
        let model = YueduDiscoveryModel { _ in calls += 1; return [] }
        let included = source("星河书源")
        var searchOnly = source("仅搜索")
        searchOnly.rawFields["exploreUrl"] = .string("  ")
        var disabled = source("已停用")
        disabled.enabled = false
        var hidden = source("隐藏发现")
        hidden.rawFields["enabledExplore"] = .bool(false)
        var comic = source("漫画")
        comic.rawFields["bookSourceType"] = .integer(2)
        let literary = source("文学馆", group: "文学；经典")
        model.updateSources([included, searchOnly, disabled, hidden, comic, literary])
        XCTAssertEqual(model.sources.map(\.id), [included.id, literary.id])
        XCTAssertEqual(Set(model.groups), ["小说", "测试", "文学", "经典"])
        XCTAssertEqual(model.filtered(query: "星河", group: "小说").map(\.id), [included.id])
        XCTAssertTrue(model.filtered(query: "星河", group: "文学").isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testExpandCachesAndRefreshReexecutesRules() async throws {
        var calls = 0
        let category = SourceCategory(title: "热门", url: "/books")
        let source = source("测试")
        let model = YueduDiscoveryModel { _ in
            calls += 1
            return [SourceCategory(title: "分类", url: ""), category, category]
        }
        model.updateSources([source])
        model.toggle(source.id)
        try await eventually { model.states[source.id] == .loaded([SourceCategory(title: "分类", url: ""), category]) }
        model.toggle(source.id)
        model.toggle(source.id)
        XCTAssertEqual(calls, 1)
        model.refreshExpanded()
        try await eventually { calls == 2 && model.states[source.id] == .loaded([SourceCategory(title: "分类", url: ""), category]) }
        model.toggle(source.id)
        model.retry(source.id)
        XCTAssertTrue(model.expanded.contains(source.id))
        try await eventually { calls == 3 && model.states[source.id] == .loaded([SourceCategory(title: "分类", url: ""), category]) }
    }

    func testFailureCanRetryAndDoesNotHideOtherSources() async throws {
        let bad = source("暂时失败")
        let good = source("正常")
        var fail = true
        let model = YueduDiscoveryModel { source in
            if source.id == bad.id && fail { throw SourceError.network("测试故障") }
            return []
        }
        model.updateSources([bad, good])
        model.toggle(bad.id)
        model.toggle(good.id)
        try await eventually { model.states[bad.id] == .failed("测试故障") && model.states[good.id] == .loaded([]) }
        fail = false
        model.retry(bad.id)
        try await eventually { model.states[bad.id] == .loaded([]) }
        XCTAssertEqual(model.sources.count, 2)
    }

    func testQueueLimitsWorkAndCollapseDiscardsLateResults() async throws {
        let sources = [source("一"), source("二"), source("三")]
        var completions: [UUID: CheckedContinuation<[SourceCategory], Never>] = [:]
        let model = YueduDiscoveryModel { source in
            await withCheckedContinuation { completions[source.id] = $0 }
        }
        model.updateSources(sources)
        for source in sources { model.toggle(source.id) }
        try await eventually { completions.count == 2 }
        XCTAssertEqual(model.states[sources[2].id], .waiting)
        model.collapseAll()
        for completion in completions.values { completion.resume(returning: [SourceCategory(title: "过期结果", url: "/old")]) }
        completions.removeAll()
        await Task.yield()
        XCTAssertTrue(model.expanded.isEmpty)
        XCTAssertTrue(model.states.isEmpty)
    }

    func testSourceEditsInvalidateCachedCategoriesAndDisableRemovesSource() async throws {
        var source = source("旧规则")
        var calls = 0
        let model = YueduDiscoveryModel { source in
            calls += 1
            return [SourceCategory(title: source.bookSourceName, url: "/books")]
        }
        model.updateSources([source])
        model.toggle(source.id)
        try await eventually { calls == 1 && model.states[source.id] == .loaded([SourceCategory(title: "旧规则", url: "/books")]) }
        source.bookSourceName = "新规则"
        model.updateSources([source])
        try await eventually { calls == 2 && model.states[source.id] == .loaded([SourceCategory(title: "新规则", url: "/books")]) }
        source.enabled = false
        model.updateSources([source])
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertTrue(model.expanded.isEmpty)
    }

    func testActualEnginePreservesCategoryHeadingsAndPageTemplates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceStore(directory: directory)
        let engine = SourceEngine(store: store, stateStore: LegadoStateStore(directory: directory))
        var source = source("真实规则")
        source.rawFields["exploreUrl"] = .string("@js:JSON.stringify([{title:'榜单',url:''},{title:'热门',url:'/books?page={{page}}'}])")
        let categories = try await engine.categories(source: source)
        XCTAssertEqual(categories, [SourceCategory(title: "榜单", url: ""), SourceCategory(title: "热门", url: "/books?page={{page}}")])
    }
}
