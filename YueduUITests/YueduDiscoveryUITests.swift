import XCTest

final class YueduDiscoveryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func importDiscoverySources() async throws -> XCUIApplication {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/discovery-sources.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let field = app.alerts["从网址导入"].textFields.firstMatch
        field.tap()
        field.typeText("http://localhost:8080/discovery-sources.json")
        app.alerts["从网址导入"].buttons["导入"].tap()
        let success = app.alerts["已导入 5 个书源"]
        XCTAssertTrue(success.waitForExistence(timeout: 12))
        success.buttons["完成"].tap()
        return app
    }

    @MainActor
    func testSourceExpansionCategoriesPaginationAndRead() async throws {
        let app = try await importDiscoverySources()
        app.tabBars.buttons["发现"].tap()
        let source = app.cells["discovery.source.本地发现·分类"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.cells["discovery.source.仅搜索书源"].exists)
        XCTAssertFalse(app.cells["discovery.source.已关闭发现"].exists)
        XCTAssertFalse(app.buttons["discovery.category.热门榜单"].exists)
        source.tap()
        let hot = app.buttons["discovery.category.热门榜单"]
        XCTAssertTrue(hot.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["榜单"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Discovery sources and categories"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        hot.tap()
        let book = app.cells.staticTexts["春日手记"]
        XCTAssertTrue(book.waitForExistence(timeout: 12))
        app.buttons["sourceExploreNextPage"].tap()
        XCTAssertTrue(app.cells.staticTexts["夏夜手记"].waitForExistence(timeout: 12))
        app.buttons["sourceExploreNextPage"].tap()
        XCTAssertFalse(app.buttons["sourceExploreNextPage"].waitForExistence(timeout: 2) && app.buttons["sourceExploreNextPage"].isHittable)
        book.tap()
        app.buttons["加入书架并阅读"].tap()
        XCTAssertTrue(app.staticTexts["reader.text"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["reader.text"].label.contains("窗边的光"))
        app.buttons["reader.back"].tap()
        app.navigationBars["书籍详情"].buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        source.tap()
        XCTAssertFalse(hot.exists)
        let search = app.searchFields["筛选书源名称、分组"]
        search.tap()
        search.typeText("动态")
        let dynamic = app.cells["discovery.source.本地发现·动态"]
        XCTAssertTrue(dynamic.waitForExistence(timeout: 3))
        XCTAssertFalse(source.exists)
        dynamic.tap()
        XCTAssertTrue(app.buttons["discovery.category.本地故事"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSourceManagementControlsDiscoveryVisibilityWithoutDisablingSearch() async throws {
        let app = try await importDiscoverySources()
        let row = app.cells["sources.row.本地发现·分类"]
        let more = row.buttons["本地发现·分类更多操作"]
        let enabled = row.switches["启用本地发现·分类"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertEqual(row.switches.count, 1)
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertFalse(more.frame.intersects(enabled.frame))
        more.tap()
        capture(app, name: "Source discovery action in more menu")
        app.buttons["在发现页隐藏"].tap()
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "发现：隐藏")).firstMatch.exists)
        XCTAssertEqual(enabled.value as? String, "1")
        capture(app, name: "Source list with one switch and more menu")
        app.tabBars.buttons["发现"].tap()
        XCTAssertFalse(app.cells["discovery.source.本地发现·分类"].exists)
        XCTAssertTrue(app.cells["discovery.source.本地发现·动态"].exists)
        app.buttons["discovery.searchBooks"].tap()
        app.searchFields["搜索书名、作者"].tap()
        app.searchFields["搜索书名、作者"].typeText("春日\n")
        let result = app.cells.staticTexts["春日手记"]
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        result.tap()
        XCTAssertTrue(app.cells["search.book.source.本地发现·分类"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["发现"].tap()
        XCTAssertFalse(app.cells["discovery.source.本地发现·分类"].exists)
        app.tabBars.buttons["书源"].tap()
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "发现：隐藏")).firstMatch.exists)
        XCTAssertEqual(enabled.value as? String, "1")
        more.tap()
        app.buttons["在发现页显示"].tap()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.cells["discovery.source.本地发现·分类"].waitForExistence(timeout: 5))
        app.tabBars.buttons["书源"].tap()
        enabled.tap()
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.tap()
        XCTAssertEqual(enabled.value as? String, "1")
        let searchOnly = app.buttons["仅搜索书源更多操作"]
        for _ in 0..<4 where !searchOnly.isHittable { app.tables["sources.list"].swipeUp() }
        searchOnly.tap()
        XCTAssertFalse(app.buttons["在发现页隐藏"].exists)
        XCTAssertFalse(app.buttons["在发现页显示"].exists)
        app.buttons["编辑书源"].tap()
        XCTAssertTrue(app.navigationBars["编辑书源"].waitForExistence(timeout: 5))
        app.navigationBars["编辑书源"].buttons.element(boundBy: 0).tap()
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(more.frame.intersects(enabled.frame))
        capture(app, name: "Source list with accessible large text")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testEmptyDiscoveryKeepsSearchAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.staticTexts["还没有可用的发现书源"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["离线试读 · 浮生六记"].exists)
        app.buttons["discovery.searchBooks"].tap()
        XCTAssertTrue(app.navigationBars["搜索书籍"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["搜索书名、作者"].exists)
    }
}
