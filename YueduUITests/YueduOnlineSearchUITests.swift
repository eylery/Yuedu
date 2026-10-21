import XCTest

final class YueduOnlineSearchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func prepare() async throws -> XCUIApplication {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/online-sources.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/online-sources.json")
        alert.buttons["导入"].tap()
        guard app.alerts["已导入 3 个书源"].waitForExistence(timeout: 12) else {
            XCTFail("测试书源导入未完成")
            return app
        }
        app.alerts["已导入 3 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        return app
    }

    @MainActor
    private func assertStatus(_ app: XCUIApplication, contains text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts["search.status"])
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
        return result == .completed
    }

    @MainActor
    private func match(_ title: String, app: XCUIApplication) {
        app.buttons["search.options"].tap()
        app.buttons["匹配方式"].tap()
        app.buttons[title].tap()
    }

    @MainActor
    func testRetryPaginationMatchingVersionSelectionAndRead() async throws {
        let app = try await prepare()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日手记\n")
        guard assertStatus(app, contains: "1 个失败") else { return }
        XCTAssertEqual(app.tables["search.results"].cells.count, 3, "同一页重复链接应去重")
        app.buttons["search.failures"].tap()
        XCTAssertTrue(app.alerts["书源搜索情况"].waitForExistence(timeout: 3))
        app.alerts.buttons["重试失败书源"].tap()
        guard assertStatus(app, contains: "4 个版本") else { return }
        XCTAssertFalse(app.buttons["search.failures"].isHittable)
        app.buttons["search.more"].tap()
        guard assertStatus(app, contains: "5 个版本") else { return }
        app.tables["search.results"].swipeUp()
        app.buttons["search.more"].tap()
        let ended = app.buttons["search.more"]
        let exhausted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已展示全部结果"), object: ended)
        XCTAssertEqual(XCTWaiter.wait(for: [exhausted], timeout: 10), .completed)
        app.tables["search.results"].swipeDown()
        app.buttons["search.options"].tap()
        app.buttons["合并同名同作者"].tap()
        match("书名完全匹配", app: app)
        XCTAssertEqual(app.tables["search.results"].cells.count, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 个版本")).firstMatch.exists)
        match("作者包含", app: app)
        XCTAssertTrue(app.cells.staticTexts["远山故事"].exists)
        XCTAssertFalse(app.cells.staticTexts["春日手记"].exists)
        app.buttons["search.options"].tap()
        app.buttons["结果排序"].tap()
        app.buttons["按书名排序"].tap()
        match("书名完全匹配", app: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Online search matching and merged versions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.cells.staticTexts["春日手记"].tap()
        XCTAssertTrue(app.navigationBars["选择书源版本"].waitForExistence(timeout: 3))
        app.cells.staticTexts["搜索测试·二号"].tap()
        app.buttons["加入书架并阅读"].tap()
        let body = app.staticTexts["reader.text"]
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "窗边的光"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 15), .completed)
    }

    @MainActor
    func testSourceGroupScopeHistoryPersistenceAndClear() async throws {
        let app = try await prepare()
        app.buttons["search.scope"].tap()
        app.buttons["清空选择"].tap()
        app.buttons["search.scope.groups"].tap()
        app.buttons["常用"].tap()
        app.buttons["选中当前列表"].tap()
        app.navigationBars["搜索范围"].buttons["应用"].tap()
        XCTAssertTrue(app.buttons["search.scope"].label.contains("2 个书源"))
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日\n")
        guard assertStatus(app, contains: "3 个版本") else { return }
        XCTAssertFalse(app.buttons["search.failures"].isHittable)
        app.buttons["search.scope"].tap()
        app.buttons["清空选择"].tap()
        app.cells["search.scope.搜索测试·二号"].tap()
        app.navigationBars["搜索范围"].buttons["应用"].tap()
        guard assertStatus(app, contains: "1 个版本") else { return }
        XCTAssertEqual(app.tables["search.results"].cells.count, 1)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        app.buttons["search.history"].tap()
        XCTAssertTrue(app.buttons["春日"].waitForExistence(timeout: 3))
        app.buttons["春日"].tap()
        guard assertStatus(app, contains: "1 个失败") else { return }
        XCTAssertEqual(app.searchFields["搜索书名、作者"].value as? String, "春日")
        app.buttons["search.history"].tap()
        app.buttons["清空搜索历史"].tap()
        app.buttons["search.history"].tap()
        XCTAssertTrue(app.buttons["暂无搜索记录"].exists)
    }
}
