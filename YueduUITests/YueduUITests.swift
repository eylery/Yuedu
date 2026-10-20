import XCTest

final class YueduUITests: XCTestCase {
    @MainActor
    func testReadBookmarkAndRestoreChapter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        let start = app.buttons["shelf.continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["reader.nextChapter"].waitForExistence(timeout: 5))
        app.buttons["reader.nextChapter"].tap()
        let chapter = app.staticTexts["reader.chapterTitle"].label
        app.buttons["reader.addBookmark"].tap()
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 3))
        if app.buttons["完成"].exists { app.buttons["完成"].tap() } else { app.swipeDown() }
        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 3))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, chapter)
        app.buttons["reader.bookmarks"].tap()
        let savedBookmark = app.tables["reader.contentsList"].staticTexts[chapter].firstMatch
        XCTAssertTrue(savedBookmark.waitForExistence(timeout: 3))
        savedBookmark.tap()
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, chapter)
    }

    @MainActor
    func testTabsAndLocalSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        app.buttons["搜索书架"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("浮生六记")
        XCTAssertTrue(app.cells.staticTexts["浮生六记"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["探索你的书源"].waitForExistence(timeout: 3))
        app.tabBars.buttons["书源"].tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 3))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.buttons["我的书签"].waitForExistence(timeout: 3))
        app.buttons["我的书签"].tap()
        XCTAssertTrue(app.staticTexts["还没有书签\n阅读时轻点书签图标，留住这一页。"].waitForExistence(timeout: 3))
    }
}
