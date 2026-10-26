import XCTest
@testable import Yuedu

@MainActor
final class YueduOnlineSearchTests: XCTestCase {
    private func source(_ name: String) -> BookSource {
        var source = BookSource.example
        source.id = UUID()
        source.bookSourceName = name
        source.bookSourceUrl = "https://fixture.invalid/\(source.id)"
        source.enabled = true
        return source
    }

    private func result(_ source: BookSource, _ title: String = "春日手记", author: String = "测试作者", path: String = "/1") -> SourceSearchResult {
        SourceSearchResult(sourceID: source.id, sourceName: source.bookSourceName, title: title,
                           author: author, summary: "", bookURL: source.bookSourceUrl + path)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待搜索状态超时", file: file, line: line)
    }

    func testEligibilityExcludesDisabledNonTextMissingSearchAndOriginalSource() {
        let good = source("正常")
        var disabled = source("停用")
        disabled.enabled = false
        var comic = source("漫画")
        comic.rawFields["bookSourceType"] = .integer(2)
        var empty = source("无搜索")
        empty.searchUrl = "  "
        let original = source("原书源")
        XCTAssertEqual(YueduOnlineSearchModel.eligible([good, disabled, comic, empty, original], excluding: original.id).map(\.id), [good.id])
    }

    func testPaginationDeduplicatesWithinAndAcrossPagesAndStopsRepeatedPages() async throws {
        let source = source("分页")
        let first = result(source)
        let second = result(source, "夏夜手记", path: "/2")
        var pages: [Int] = []
        let model = YueduOnlineSearchModel { _, _, page in
            pages.append(page)
            return page == 1 ? [first, first] : [first, second, second]
        }
        model.search("手记", sources: [source])
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.results.count, 1)
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.results.count, 2)
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertFalse(model.canLoadMore)
        model.loadMore()
        XCTAssertEqual(pages, [1, 2, 3])
    }

    func testFailureRetryKeepsPageAndOtherSourceResults() async throws {
        let good = source("正常")
        let bad = source("暂时故障")
        let first = result(good)
        let recovered = result(bad)
        var calls: [UUID: [Int]] = [:]
        var shouldFail = true
        let model = YueduOnlineSearchModel { source, _, page in
            calls[source.id, default: []].append(page)
            if source.id == bad.id && shouldFail { throw SourceError.network("暂时不可用") }
            return source.id == good.id ? [first] : [recovered]
        }
        model.search("春日", sources: [good, bad])
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.failures.first?.nextPage, 1)
        XCTAssertEqual(model.results.count, 1)
        shouldFail = false
        model.retryFailures()
        try await eventually { !model.isSearching }
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(calls[good.id], [1])
        XCTAssertEqual(calls[bad.id], [1, 1])
    }

    func testLaterPageFailureDoesNotSkipPageOrEraseEarlierResults() async throws {
        let source = source("分页故障")
        let first = result(source)
        let second = result(source, path: "/2")
        var failure = true
        var pages: [Int] = []
        let model = YueduOnlineSearchModel { _, _, page in
            pages.append(page)
            if page == 2 && failure { throw SourceError.network("第二页失败") }
            return page == 1 ? [first] : [second]
        }
        model.search("春日", sources: [source])
        try await eventually { !model.isSearching }
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.results, [first])
        XCTAssertEqual(model.failures.first?.nextPage, 2)
        failure = false
        model.retryFailures()
        try await eventually { !model.isSearching }
        XCTAssertEqual(pages, [1, 2, 2])
        XCTAssertEqual(model.results, [first, second])
    }

    func testCancelLimitsConcurrencyRetainsResultsAndDiscardsLateCallbacks() async throws {
        let sources = (1...6).map { source("书源\($0)") }
        var pending: [UUID: CheckedContinuation<[SourceSearchResult], Never>] = [:]
        let model = YueduOnlineSearchModel { source, _, _ in
            await withCheckedContinuation { pending[source.id] = $0 }
        }
        model.search("春日", sources: sources)
        try await eventually { pending.count == 4 }
        pending.removeValue(forKey: sources[0].id)?.resume(returning: [result(sources[0])])
        try await eventually { model.results.count == 1 && pending[sources[4].id] != nil }
        model.cancel()
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.wasCancelled)
        XCTAssertNil(pending[sources[5].id])
        for (id, continuation) in pending {
            continuation.resume(returning: [result(sources.first { $0.id == id }!)])
        }
        pending.removeAll()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.results.map(\.sourceID), [sources[0].id])
        XCTAssertEqual(model.states.first { $0.source.id == sources[1].id }?.nextPage, 1)
    }

    func testNewQueryDiscardsUncooperativeOldRequest() async throws {
        let source = source("测试")
        let old = result(source, "旧关键词")
        let new = result(source, "新关键词", path: "/2")
        var pending: CheckedContinuation<[SourceSearchResult], Never>?
        let model = YueduOnlineSearchModel { _, query, _ in
            if query == "旧" { return await withCheckedContinuation { pending = $0 } }
            return [new]
        }
        model.search("旧", sources: [source])
        try await eventually { pending != nil }
        model.search("新", sources: [source])
        try await eventually { !model.isSearching }
        pending?.resume(returning: [old])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.query, "新")
        XCTAssertEqual(model.results, [new])
    }

    func testContinueAfterCancellationRetriesUnfinishedPage() async throws {
        let source = source("继续搜索")
        let first = result(source)
        let second = result(source, path: "/2")
        var pending: CheckedContinuation<[SourceSearchResult], Never>?
        var pages: [Int] = []
        var pause = true
        let model = YueduOnlineSearchModel { _, _, page in
            pages.append(page)
            if page == 2 && pause { return await withCheckedContinuation { pending = $0 } }
            return page == 1 ? [first] : [second]
        }
        model.search("春日", sources: [source])
        try await eventually { !model.isSearching }
        model.loadMore()
        try await eventually { pending != nil }
        model.cancel()
        pending?.resume(returning: [second])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.results, [first])
        pause = false
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertEqual(pages, [1, 2, 2])
        XCTAssertEqual(model.results, [first, second])
        XCTAssertFalse(model.wasCancelled)
    }

    func testSourceEditsRemoveStaleResultsAndIgnoreLateRequests() async throws {
        var source = source("编辑前")
        let first = result(source)
        var pending: CheckedContinuation<[SourceSearchResult], Never>?
        let model = YueduOnlineSearchModel { _, _, page in
            if page == 1 { return [first] }
            return await withCheckedContinuation { pending = $0 }
        }
        model.search("春日", sources: [source])
        try await eventually { !model.isSearching }
        model.loadMore()
        try await eventually { pending != nil }
        source.searchUrl = "/changed"
        model.updateSources([source])
        pending?.resume(returning: [result(source, path: "/2")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertTrue(model.sourcesChanged)
        XCTAssertFalse(model.isSearching)
    }

    func testMatchingRankingAndConservativeVersionMerging() async throws {
        let first = source("第一源")
        let second = source("第二源")
        let exact = result(first)
        let same = result(second, "春日 手记", author: "测试作者")
        let otherAuthor = result(first, author: "其他作者", path: "/2")
        let contains = result(first, "春日手记续篇", path: "/3")
        let authorMatch = result(first, "另一部书", author: "春日手记", path: "/4")
        let unknown = result(first, "无名书", author: "未知作者", path: "/5")
        let unknown2 = result(second, "无名书", author: "未知作者", path: "/6")
        let model = YueduOnlineSearchModel { source, _, _ in
            source.id == first.id ? [contains, otherAuthor, exact, authorMatch, unknown] : [same, unknown2]
        }
        model.search("春日手记", sources: [first, second])
        try await eventually { !model.isSearching }
        let merged = model.rows(match: .all, sort: .relevance, merge: true)
        XCTAssertEqual(merged.count, 6)
        XCTAssertEqual(merged.first { $0.book.author == "测试作者" && YueduCatalog.normalized($0.book.title) == "春日手记" }?.versions.count, 2)
        XCTAssertEqual(merged.filter { $0.book.title == "无名书" }.count, 2)
        XCTAssertEqual(model.rows(match: .exactTitle, sort: .relevance, merge: false).count, 3)
        XCTAssertEqual(model.rows(match: .title, sort: .title, merge: false).count, 4)
        XCTAssertEqual(model.rows(match: .author, sort: .author, merge: true).map(\.book.title), ["另一部书"])
        XCTAssertEqual(Set(model.rows(match: .all, sort: .source, merge: false).prefix(5).map(\.book.sourceID)), [first.id])
        XCTAssertEqual(model.rows(match: .all, sort: .relevance, merge: false, requiredTitle: "春日手记").count, 3)
    }

    func testAuthorAnnotationsAndInvisibleFormattingMergeWithoutRewritingResults() async throws {
        let first = source("超星")
        let second = source("其他源")
        let authors = ["吴承恩", "（明）吴承恩", ".（明）吴承恩", ".（明）吴承恩撰",
                       "作者：吴承恩 著", "[明代] 吴承恩", "吴\u{200B}承恩", "吴承恩（著）"]
        let incoming = authors.enumerated().map { index, author in
            result(first, index == 0 ? "《西游记》" : "西游\u{FEFF}记", author: author, path: "/\(index)")
        }
        let another = result(second, " 西 游 记 ", author: "吴承恩")
        let adapted = result(first, "西游记", author: "刘敬余编", path: "/adapted")
        let unknown = result(first, "西游记", author: "未知作者", path: "/unknown")
        let unknown2 = result(second, "西游记", author: "佚名", path: "/unknown")
        let model = YueduOnlineSearchModel { source, _, _ in
            source.id == first.id ? incoming + [adapted, unknown] : [another, unknown2]
        }
        model.search("西游记", sources: [first, second])
        try await eventually { !model.isSearching }
        let merged = model.rows(match: .exactTitle, sort: .relevance, merge: true)
        XCTAssertEqual(merged.count, 4)
        let original = try XCTUnwrap(merged.first { $0.author == "吴承恩" })
        XCTAssertEqual(original.versions.count, 9)
        XCTAssertEqual(original.sourceCount, 2)
        XCTAssertEqual(original.title.replacingOccurrences(of: " ", with: ""), "西游记")
        XCTAssertEqual(Set(original.versions.map(\.id)), Set((incoming + [another]).map(\.id)))
        XCTAssertEqual(model.results.first { $0.id == incoming[3].id }?.author, ".（明）吴承恩撰")
        XCTAssertEqual(model.rows(match: .all, sort: .relevance, merge: false).count, 12)
    }

    func testIdentityKeepsDifferentWorksCreditsAliasesAndUnknownAuthorsSeparate() {
        for author in ["（明）吴承恩", ".（明）吴承恩撰", "作者：吴承恩 著", "吴承恩（著）"] {
            XCTAssertEqual(YueduSearchIdentity.authorKey(author), "吴承恩")
        }
        for author in ["吴承恩编著", "吴承恩译", "吴承恩编撰", "吴承恩、张三", "吴承恩改编", "(笔名)吴承恩"] {
            XCTAssertNotEqual(YueduSearchIdentity.authorKey(author), "吴承恩", author)
        }
        XCTAssertNotEqual(YueduSearchIdentity.titleKey("西游记续篇"), YueduSearchIdentity.titleKey("西游记"))
        XCTAssertNotEqual(YueduSearchIdentity.titleKey("西游记（少儿版）"), YueduSearchIdentity.titleKey("西游记"))
        XCTAssertEqual(YueduSearchIdentity.titleKey("《ＡＢＣ》"), "abc")
        XCTAssertEqual(YueduSearchIdentity.authorKey("王著"), "王著")
        for author in ["", "（明）佚名", "未知作者", "作者：不详", "匿名"] {
            XCTAssertNil(YueduSearchIdentity.authorKey(author), author)
        }
    }

    func testAuthorFilterUsesTheSameIdentityAsGrouping() async throws {
        let source = source("作者标注")
        let book = result(source, "西游记", author: ".（明）吴承恩撰")
        let model = YueduOnlineSearchModel { _, _, _ in [book] }
        model.search("作者：吴承恩 著", sources: [source])
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.rows(match: .author, sort: .relevance, merge: true).count, 1)
    }

    func testSourceGroupingKeepsDistinctLinksAndSourceConfigurations() {
        let first = source("同名书源")
        let second = source("同名书源")
        let a = result(first)
        let b = result(first, path: "/2")
        let c = SourceSearchResult(sourceID: second.id, sourceName: second.bookSourceName,
                                   title: a.title, author: a.author, summary: "", bookURL: a.bookURL)
        let groups = YueduSearchSourceGroup.grouped([a, a, c, b])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].records.map(\.id), [a.id, b.id])
        XCTAssertEqual(groups[1].records.map(\.id), [c.id])
    }

    func testFilteredEmptyPageStillAllowsPagination() async throws {
        let source = source("精确匹配")
        let unrelated = result(source, "无关书")
        let exact = result(source, path: "/2")
        let model = YueduOnlineSearchModel { _, _, page in page == 1 ? [unrelated] : [exact] }
        model.search("春日手记", sources: [source])
        try await eventually { !model.isSearching }
        XCTAssertTrue(model.rows(match: .exactTitle, sort: .relevance, merge: true).isEmpty)
        XCTAssertTrue(model.canLoadMore)
        model.loadMore()
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.rows(match: .exactTitle, sort: .relevance, merge: true).count, 1)
    }

    func testResetDiscardsPendingSearchAndLateResults() async throws {
        let source = source("清空搜索")
        var pending: CheckedContinuation<[SourceSearchResult], Never>?
        let model = YueduOnlineSearchModel { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        model.search("旧关键词", sources: [source])
        try await eventually { pending != nil }
        model.reset()
        pending?.resume(returning: [result(source)])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.canLoadMore)
        XCTAssertFalse(model.wasCancelled)
    }

    func testQuickSearchAndPatientRetryUseDifferentBudgets() async throws {
        let source = source("慢书源")
        var budgets: [TimeInterval] = []
        var pages: [Int] = []
        let model = YueduOnlineSearchModel(timedLoader: { _, _, page, timeout in
            budgets.append(timeout)
            pages.append(page)
            if timeout < 20 { throw SourceError.network("超时") }
            return [self.result(source)]
        })
        model.search("春日", sources: [source])
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.failures.count, 1)
        model.retryFailures()
        try await eventually { !model.isSearching }
        XCTAssertEqual(budgets, [12, 30])
        XCTAssertEqual(pages, [1, 1])
        XCTAssertEqual(model.results.count, 1)
        XCTAssertTrue(model.failures.isEmpty)
    }

    func testSuccessfulSourceStartsAheadOfPreviouslyFailedSources() async throws {
        let sources = (1...6).map { source("优先级\($0)") }
        let healthy = sources[5]
        var pending: [UUID: CheckedContinuation<[SourceSearchResult], Never>] = [:]
        var secondQuery = false
        let model = YueduOnlineSearchModel { source, _, _ in
            if secondQuery {
                return await withCheckedContinuation { pending[source.id] = $0 }
            }
            if source.id != healthy.id { throw SourceError.network("故障") }
            return [self.result(source)]
        }
        model.search("第一次", sources: sources)
        try await eventually { !model.isSearching }
        secondQuery = true
        model.search("第二次", sources: sources)
        try await eventually { pending.count == 4 }
        XCTAssertNotNil(pending[healthy.id], "上次成功的书源应进入首批，无需排在故障源之后")
        model.cancel()
        pending.values.forEach { $0.resume(returning: []) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(model.results.isEmpty)
    }

    func testHistoryDeduplicatesLimitsPersistsAndClears() {
        let suite = "YueduSearchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = YueduSearchHistory(defaults: defaults)
        history.record("  春日手记  ")
        history.record("春日 手记")
        history.record("  ")
        XCTAssertEqual(history.queries, ["春日 手记"])
        for index in 0..<25 { history.record("小说\(index)") }
        XCTAssertEqual(history.queries.count, 20)
        XCTAssertEqual(YueduSearchHistory(defaults: defaults).queries.first, "小说24")
        history.clear()
        XCTAssertTrue(history.queries.isEmpty)
    }
}
