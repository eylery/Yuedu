import XCTest

final class YueduCacheManagementUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval = 15) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing element: \(element)")
            throw NSError(domain: "YueduCacheManagementUITests", code: 1)
        }
    }

    @MainActor
    private func expectText(_ element: XCUIElement, _ text: String) throws {
        try require(element)
        let label = element.elementType == .cell
            ? element.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch : element
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: label)
        guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
            XCTFail("Expected text: \(text)")
            throw NSError(domain: "YueduCacheManagementUITests", code: 2)
        }
    }

    @MainActor
    private func tap(_ element: XCUIElement, in table: XCUIElement) throws {
        for _ in 0..<8 where !element.isHittable { table.swipeUp() }
        try require(element)
        element.tap()
    }

    @MainActor
    private func top(_ table: XCUIElement) {
        for _ in 0..<4 { table.swipeDown() }
    }

    @MainActor
    private func openCache(_ app: XCUIApplication) throws {
        app.buttons["reader.details"].tap()
        try tap(app.cells["bookDetail.online.5"], in: app.tables["bookDetail.list"])
        try require(app.navigationBars["本书缓存"])
    }

    @MainActor
    func testRangePauseRestartRetryCleanupAndOfflineProtection() async throws {
        _ = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/cache/reset")!)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let importAlert = app.alerts["从网址导入"]
        importAlert.textFields.firstMatch.tap()
        importAlert.textFields.firstMatch.typeText("http://localhost:8080/cache-source.json")
        importAlert.buttons["导入"].tap()
        try require(app.alerts["已导入 1 个书源"])
        app.alerts.buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("缓存\n")
        try require(app.cells.staticTexts["缓存管理手记"])
        app.cells.staticTexts["缓存管理手记"].tap()
        app.buttons["加入书架并阅读"].tap()
        try expectText(app.staticTexts["reader.text"], "第1章缓存管理正文")
        app.scrollViews["reader.content"].swipeUp()
        app.buttons["reader.addBookmark"].tap()
        try openCache(app)
        let table = app.tables["cache.list"]
        try tap(app.cells["cache.action.2"], in: table)
        let range = app.alerts["指定范围缓存"]
        let first = range.textFields.element(boundBy: 0)
        first.tap()
        first.typeText(XCUIKeyboardKey.delete.rawValue + "2")
        let last = range.textFields.element(boundBy: 1)
        last.tap()
        last.typeText(XCUIKeyboardKey.delete.rawValue + "3")
        range.buttons["开始缓存"].tap()
        try tap(app.cells["cache.action.3"], in: table)
        top(table)
        try expectText(app.cells["cache.summary"], "已暂停")
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        try openCache(app)
        try expectText(app.cells["cache.summary"], "已暂停")
        try tap(app.cells["cache.action.3"], in: table)
        top(table)
        try expectText(app.cells["cache.summary"], "1 章失败")
        try tap(app.cells["cache.action.4"], in: table)
        top(table)
        try expectText(app.cells["cache.summary"], "缓存完成")
        try expectText(app.cells["cache.summary"], "已缓存 3 章")
        let (statsData, _) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/cache/stats")!)
        let counts = (try JSONSerialization.jsonObject(with: statsData) as? [String: Any])?["counts"] as? [String: Int]
        XCTAssertNil(counts?["4"])
        XCTAssertNil(counts?["5"])
        XCTAssertEqual(counts?["3"], 2)

        // Read the third chapter, then clear read chapters: the bookmarked first and current third survive.
        try tap(app.cells["cache.chapter.2"], in: table)
        app.buttons["阅读本章"].tap()
        try expectText(app.staticTexts["reader.text"], "第3章缓存管理正文")
        app.scrollViews["reader.content"].swipeUp()
        let progress = yueduReadingInfo(app)
        try openCache(app)
        try tap(app.cells["cache.action.6"], in: table)
        try require(app.alerts["清理已读章节缓存"])
        app.alerts.buttons["清理缓存"].tap()
        top(table)
        try expectText(app.cells["cache.summary"], "已缓存 2 章")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cache management after protected cleanup"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.switches["启用缓存管理测试源"].tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf.continue"].tap()
        try expectText(app.staticTexts["reader.text"], "第3章缓存管理正文")
        XCTAssertEqual(yueduReadingInfo(app), progress)
        app.buttons["reader.bookmarks"].tap()
        try require(app.cells.staticTexts["第1章 缓存测试"])
        app.cells.staticTexts["第1章 缓存测试"].tap()
        try expectText(app.staticTexts["reader.text"], "第1章缓存管理正文")
        app.buttons["reader.nextChapter"].tap()
        try require(app.buttons["reader.retry"])
        try expectText(app.staticTexts["reader.status"], "章节加载失败")

        // Global batch cleanup removes only online bodies, keeps the book itself and its bookmark.
        app.terminate()
        app.launch()
        app.tabBars.buttons["我的"].tap()
        try require(app.buttons["缓存管理"])
        app.buttons["缓存管理"].tap()
        try require(app.navigationBars["缓存管理"])
        app.buttons["cache.select"].tap()
        app.buttons["cache.selectAll"].tap()
        app.buttons["cache.clearSelected"].tap()
        try require(app.alerts["清理所选书籍缓存"])
        app.alerts.buttons["取消"].tap()
        try expectText(app.cells["cache.summary"], "已缓存 2 章")
        app.buttons["cache.clearSelected"].tap()
        app.alerts.buttons["清理缓存"].tap()
        try expectText(app.cells["cache.summary"], "已缓存 0 章")
        XCTAssertTrue(app.cells.staticTexts["缓存管理手记"].exists)
    }
}
