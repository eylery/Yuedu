import XCTest

final class YueduDiscoveryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testSourceExpansionCategoriesPaginationAndRead() async throws {
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
