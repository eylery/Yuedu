import XCTest

final class YueduPurificationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing element: \(element)")
            throw NSError(domain: "YueduPurificationUITests", code: 1)
        }
    }

    @MainActor
    private func expect(_ element: XCUIElement, contains text: String, present: Bool = true) throws {
        let predicate = NSPredicate(format: present ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", text)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 15)
        guard result == .completed else {
            XCTFail("Unexpected text: \(element.label)")
            throw NSError(domain: "YueduPurificationUITests", code: 2)
        }
    }

    @MainActor
    private func openTools(_ app: XCUIApplication) throws {
        app.buttons["reader.settings"].tap()
        try require(app.buttons["readingSettings.purification"])
        app.buttons["readingSettings.purification"].tap()
        try require(app.navigationBars["正文净化"])
    }

    @MainActor
    private func returnToReader(_ app: XCUIApplication) {
        app.navigationBars["正文净化"].buttons["BackButton"].tap()
        app.navigationBars["阅读设置"].buttons["完成"].tap()
    }

    @MainActor
    func testPreviewRegexCleaningCurlPersistenceAndOfflineOriginal() async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/purification-source.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/purification-source.json")
        alert.buttons["导入"].tap()
        try require(app.alerts["已导入 1 个书源"])
        app.alerts.buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("净化\n")
        try require(app.cells.staticTexts["净化测试手记"])
        app.cells.staticTexts["净化测试手记"].tap()
        app.buttons["加入书架并阅读"].tap()
        let body = app.staticTexts["reader.text"]
        try expect(body, contains: "净化测试广告")
        app.scrollViews["reader.content"].swipeUp()
        app.buttons["reader.addBookmark"].tap()
        let progressBeforeCleaning = app.staticTexts["reader.progress"].label
        try openTools(app)
        app.navigationBars["正文净化"].buttons["添加净化规则"].tap()
        app.buttons["自定义替换规则"].tap()
        let name = app.textFields["purification.name"]
        name.tap()
        name.typeText("本书去广告")
        app.buttons["正则替换"].tap()
        let pattern = app.textViews["purification.pattern"]
        pattern.tap()
        pattern.typeText("[")
        app.navigationBars["编辑净化规则"].buttons["保存"].tap()
        try require(app.alerts["无法保存规则"])
        app.alerts.buttons.firstMatch.tap()
        pattern.tap()
        pattern.typeText(XCUIKeyboardKey.delete.rawValue + "(?m)^推广：[^\\n]*\\n?")
        app.navigationBars["编辑净化规则"].buttons["预览"].tap()
        app.navigationBars["净化预览"].buttons["运行预览"].tap()
        try expect(app.staticTexts["purification.report"], contains: "本书去广告：1 处")
        let output = app.textViews["purification.output"]
        XCTAssertTrue((output.value as? String)?.contains("正文应始终保留") == true)
        XCTAssertFalse((output.value as? String)?.contains("净化测试广告") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Purification preview preserves chapter body"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["原文 / 可粘贴"].tap()
        XCTAssertTrue((app.textViews["purification.original"].value as? String)?.contains("净化测试广告") == true)
        app.navigationBars["净化预览"].buttons["BackButton"].tap()
        app.navigationBars["编辑净化规则"].buttons["保存"].tap()
        try require(app.cells["purification.rule.本书去广告"])
        returnToReader(app)
        try expect(body, contains: "正文应始终保留")
        try expect(body, contains: "净化测试广告", present: false)
        XCTAssertEqual(app.staticTexts["reader.progress"].label, progressBeforeCleaning)
        XCTAssertEqual(app.buttons["reader.addBookmark"].label, "移除此处书签")
        app.buttons["reader.settings"].tap()
        let slide = app.buttons["平移翻页"]
        if !slide.isHittable { app.scrollViews.firstMatch.swipeUp() }
        slide.tap()
        app.navigationBars["阅读设置"].buttons["完成"].tap()
        let page = app.staticTexts["reader.pageText"].firstMatch
        try require(page)
        try expect(page, contains: "正文应始终保留")
        try expect(page, contains: "净化测试广告", present: false)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        try require(page)
        try expect(page, contains: "净化测试广告", present: false)
        try openTools(app)
        app.switches["purification.bookEnabled"].tap()
        app.navigationBars["正文净化"].buttons["BackButton"].tap()
        let scroll = app.buttons["上下滚动"]
        if !scroll.isHittable { app.scrollViews.firstMatch.swipeUp() }
        scroll.tap()
        app.navigationBars["阅读设置"].buttons["完成"].tap()
        try expect(body, contains: "净化测试广告")
        app.buttons["reader.back"].tap()
        app.tabBars.buttons["书源"].tap()
        app.switches["启用净化测试书源"].tap()
        app.terminate()
        app.launch()
        app.buttons["shelf.continue"].tap()
        try expect(body, contains: "净化测试广告")
        try expect(body, contains: "正文应始终保留")
    }
}
