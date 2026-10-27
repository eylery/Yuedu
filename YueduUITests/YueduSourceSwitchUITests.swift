import XCTest

final class YueduSourceSwitchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval = 12) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing element: \(element)")
            throw NSError(domain: "YueduSourceSwitchUITests", code: 1)
        }
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: NSPredicate) throws {
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 15) == .completed else {
            XCTFail("Unexpected element state: \(element)")
            throw NSError(domain: "YueduSourceSwitchUITests", code: 2)
        }
    }

    @MainActor
    private func contains(_ element: XCUIElement, _ text: String) throws {
        try require(element)
        if element.elementType == .cell {
            try require(element.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch)
            return
        }
        try expect(element, NSPredicate(format: "exists == true AND label CONTAINS %@", text))
    }

    @MainActor
    private func tap(_ element: XCUIElement, scrolling table: XCUIElement) throws {
        for _ in 0..<6 where !element.isHittable { table.swipeUp() }
        try expect(element, NSPredicate(format: "exists == true AND hittable == true"))
        element.tap()
    }

    @MainActor
    private func result(_ app: XCUIApplication, source: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", source)).firstMatch
    }

    @MainActor
    private func launchFixture() async throws -> XCUIApplication {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/switch/reset")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/switch-sources.json")
        alert.buttons["导入"].tap()
        try require(app.alerts["已导入 3 个书源"])
        app.alerts.buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("换源\n")
        try contains(app.staticTexts["search.status"], "3 条收录")
        let original = result(app, source: "阅读测试")
        try require(original)
        original.tap()
        app.cells["search.book.source.换源测试·原源"].tap()
        app.buttons["加入书架并阅读"].tap()
        try contains(app.staticTexts["reader.text"], "原版本初见正文")
        return app
    }

    @MainActor
    func testFailedChapterSwitchPreviewRetryCancelManualSelectionAndOfflineReturn() async throws {
        let app = try await launchFixture()
        app.scrollViews["reader.content"].swipeUp()
        yueduSetReadingTools(app, visible: true)
        app.buttons["reader.addBookmark"].tap()
        let originalProgress = yueduReadingInfo(app)
        app.buttons["reader.nextChapter"].tap()
        try require(app.buttons["reader.switchSource"])
        app.buttons["reader.switchSource"].tap()
        let alternate = result(app, source: "换源测试·备用")
        try require(alternate)
        alternate.tap()
        try require(app.navigationBars["换源对比"])
        try contains(app.cells["sourceSwitch.chapter"], "第2章：重逢")
        let confirm = app.buttons["sourceSwitch.confirm"]
        XCTAssertFalse(confirm.isEnabled)
        let table = app.tables["sourceSwitch.list"]
        let preview = app.cells["sourceSwitch.preview"]
        try tap(preview, scrolling: table)
        let failed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "试读失败")).firstMatch
        try require(failed)
        XCTAssertFalse(confirm.isEnabled)
        preview.tap()
        try contains(preview, "取消试读")
        preview.tap()
        XCTAssertFalse(confirm.isEnabled)
        preview.tap()
        try expect(confirm, NSPredicate(format: "enabled == true"))
        try contains(app.cells["sourceSwitch.previewText"], "备用版本重逢正文")

        // Selecting a chapter again invalidates the prior preview and defaults to chapter start.
        table.swipeDown()
        app.cells["sourceSwitch.chapter"].tap()
        try require(app.cells["reader.chapter.2"])
        app.cells["reader.chapter.2"].tap()
        try require(app.navigationBars["换源对比"])
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertEqual(app.switches["sourceSwitch.fraction"].value as? String, "0")
        try tap(preview, scrolling: table)
        try expect(confirm, NSPredicate(format: "enabled == true"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Source switch comparison and verified chapter"
        attachment.lifetime = .keepAlways
        add(attachment)
        confirm.tap()
        try contains(app.staticTexts["reader.chapterTitle"], "第2章：重逢")
        try contains(app.staticTexts["reader.text"], "备用版本重逢正文")

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["书源"].tap()
        for name in ["换源测试·原源", "换源测试·备用"] {
            let toggle = app.switches["启用\(name)"]
            try require(toggle)
            toggle.tap()
        }
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf.continue"].tap()
        try contains(app.staticTexts["reader.text"], "备用版本重逢正文")
        app.buttons["reader.bookmarks"].tap()
        try require(app.cells.staticTexts["第一章 初见"].firstMatch)
        app.navigationBars["换源测试小说"].buttons["完成"].tap()
        app.buttons["reader.details"].tap()
        app.cells["bookDetail.editions"].tap()
        try require(app.navigationBars["已保存版本"])
        app.cells.staticTexts["换源测试·原源"].tap()
        try contains(app.staticTexts["reader.text"], "原版本初见正文")
        XCTAssertEqual(yueduReadingInfo(app), originalProgress)
        app.buttons["reader.bookmarks"].tap()
        try require(app.cells.staticTexts["第一章 初见"].firstMatch)
    }

    @MainActor
    func testDifferentAuthorRequiresManualChapterAndExplicitConfirmation() async throws {
        let app = try await launchFixture()
        app.buttons["reader.details"].tap()
        app.cells["bookDetail.online.1"].tap()
        let unrelated = result(app, source: "换源测试·同名异书")
        try require(unrelated)
        unrelated.tap()
        try require(app.navigationBars["换源对比"])
        try contains(app.cells["sourceSwitch.chapter"], "未找到唯一匹配")
        let table = app.tables["sourceSwitch.list"]
        app.cells["sourceSwitch.chapter"].tap()
        try require(app.cells["reader.chapter.0"])
        app.cells["reader.chapter.0"].tap()
        let preview = app.cells["sourceSwitch.preview"]
        try tap(preview, scrolling: table)
        let confirm = app.buttons["sourceSwitch.confirm"]
        try expect(confirm, NSPredicate(format: "enabled == true"))
        confirm.tap()
        try require(app.alerts["确认是同一部作品？"])
        app.alerts.buttons["继续核对"].tap()
        XCTAssertTrue(app.navigationBars["换源对比"].exists)
        // Leaving without confirmation must not create a second shelf edition.
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        try contains(app.staticTexts["reader.text"], "原版本初见正文")
        app.buttons["reader.details"].tap()
        XCTAssertFalse(app.cells["bookDetail.editions"].exists)
    }
}
