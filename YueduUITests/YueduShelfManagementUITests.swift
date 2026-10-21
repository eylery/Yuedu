import XCTest

final class YueduShelfManagementUITests: XCTestCase {
    @MainActor
    func testEmptyShelfAndMinimalDiscover() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.emptyAction"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["shelf.continue"].exists)
        XCTAssertFalse(app.buttons["book.浮生六记"].exists)
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["discovery.searchBooks"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["离线试读 · 浮生六记"].exists)
        app.tabBars.buttons["书架"].tap()
        app.buttons["添加书籍"].tap()
        app.buttons["离线试读 · 浮生六记"].tap()
        XCTAssertTrue(app.buttons["reader.back"].waitForExistence(timeout: 5))
        app.buttons["reader.back"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["book.浮生六记"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shelf with one chosen book"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testBatchGroupStatePinAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.manage"].waitForExistence(timeout: 10))
        app.buttons["shelf.manage"].tap()
        XCTAssertFalse(app.buttons["shelf.batch.remove"].isEnabled)
        app.buttons["book.浮生六记"].tap()
        app.buttons["shelf.batch.分组"].tap()
        app.buttons["新建分组并移入…"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("追更")
        app.alerts.buttons["创建并移入"].tap()
        app.buttons["shelf.batch.状态"].tap()
        app.buttons.matching(identifier: "已读").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        app.buttons["shelf.batch.置顶"].tap()
        app.buttons.matching(identifier: "置顶").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        app.buttons["shelf.batch.remove"].tap()
        XCTAssertTrue(app.alerts["移除 1 本书？"].waitForExistence(timeout: 3))
        app.alerts.buttons["取消"].tap()
        app.buttons["shelf.manage"].tap()
        app.buttons["shelf.groups"].tap()
        app.buttons["追更"].tap()
        XCTAssertTrue(app.buttons["book.浮生六记"].exists)
        XCTAssertFalse(app.buttons["shelf.continue"].exists)
        XCTAssertEqual(app.buttons["book.浮生六记"].value as? String, "置顶 · 已读")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Grouped shelf"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.groups"].tap()
        app.buttons["追更"].tap()
        XCTAssertEqual(app.buttons["book.浮生六记"].value as? String, "置顶 · 已读")
        app.buttons["shelf.manage"].tap()
        app.buttons["shelf.selectAll"].tap()
        app.buttons["shelf.batch.remove"].tap()
        app.alerts.buttons["移除"].tap()
        XCTAssertTrue(app.buttons["shelf.emptyAction"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["book.浮生六记"].exists)
    }

    @MainActor
    func testGroupRenameAndDelete() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.groups"].waitForExistence(timeout: 10))
        app.buttons["shelf.groups"].tap()
        app.buttons["管理分组"].tap()
        app.navigationBars.buttons["新建"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("旧分组")
        app.alerts.buttons["保存"].tap()
        let group = app.tables["shelf.groupList"].cells.staticTexts["旧分组"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.tap()
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "新分组")
        app.alerts.buttons["保存"].tap()
        let renamed = app.tables["shelf.groupList"].cells.containing(.staticText, identifier: "新分组").firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        renamed.swipeLeft()
        app.buttons["删除"].tap()
        app.alerts.buttons["删除分组"].tap()
        XCTAssertFalse(app.tables["shelf.groupList"].cells.staticTexts["新分组"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["shelf.emptyAction"].waitForExistence(timeout: 3))
    }

}
