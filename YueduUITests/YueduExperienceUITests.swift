import XCTest

final class YueduExperienceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["readingSettings.content"]
        for _ in 0..<9 where !element.isHittable {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.85)).press(
                forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2))
            )
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNightAppearanceLargeTextAndPrefetchPreferenceSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 8))
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(app.buttons["reader.settings"].waitForExistence(timeout: 8))
        app.buttons["reader.settings"].tap()
        let night = app.buttons["readingSettings.theme.night"]
        reveal(night, in: app)
        night.tap()
        let prefetch = app.switches["readingSettings.prefetch"]
        reveal(prefetch, in: app)
        XCTAssertEqual(prefetch.value as? String, "1")
        prefetch.tap()
        capture(app, name: "Night reading settings")
        app.buttons["完成"].tap()
        app.buttons["reader.back"].tap()
        capture(app, name: "Night bookshelf")
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 8))
        capture(app, name: "Accessible large text bookshelf")
        app.tabBars.buttons["我的"].tap()
        let settings = app.buttons["阅读设置"].firstMatch
        for _ in 0..<5 where !settings.isHittable { app.scrollViews.firstMatch.swipeUp() }
        settings.tap()
        reveal(prefetch, in: app)
        XCTAssertEqual(prefetch.value as? String, "0")
        capture(app, name: "Accessible large text settings")
    }

    @MainActor
    func testNextChapterPrefetchIsSharedAndCanBeDisabled() async throws {
        _ = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/cache/reset")!)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        app.alerts["从网址导入"].textFields.firstMatch.tap()
        app.alerts["从网址导入"].textFields.firstMatch.typeText("http://localhost:8080/cache-source.json")
        app.alerts["从网址导入"].buttons["导入"].tap()
        XCTAssertTrue(app.alerts["已导入 1 个书源"].waitForExistence(timeout: 12))
        app.alerts["已导入 1 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        app.searchFields["搜索书名、作者"].tap()
        app.searchFields["搜索书名、作者"].typeText("缓存管理手记\n")
        XCTAssertTrue(app.cells.staticTexts["缓存管理手记"].waitForExistence(timeout: 12))
        app.cells.staticTexts["缓存管理手记"].tap()
        app.buttons["search.book.read"].tap()
        XCTAssertTrue(app.staticTexts["reader.text"].waitForExistence(timeout: 12))
        let content = app.scrollViews["reader.content"]
        for _ in 0..<7 where !app.buttons["reader.nextChapterAtEnd"].isHittable { content.swipeUp() }
        var counts: [String: Int] = [:]
        for _ in 0..<40 {
            counts = try await cacheCounts()
            if counts["2"] == 1 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(counts["2"], 1, "章末应在打开第二章前开始预取")
        yueduSetReadingTools(app, visible: true)
        app.buttons["reader.nextChapter"].tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "第2章缓存管理正文"), object: app.staticTexts["reader.text"])
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 12), .completed)
        counts = try await cacheCounts()
        XCTAssertEqual(counts["2"], 1, "阅读与预取不能重复请求同一章")
        app.buttons["reader.settings"].tap()
        let toggle = app.switches["readingSettings.prefetch"]
        reveal(toggle, in: app)
        toggle.tap()
        app.buttons["完成"].tap()
        for _ in 0..<7 where !app.buttons["reader.nextChapterAtEnd"].isHittable { content.swipeUp() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        counts = try await cacheCounts()
        XCTAssertNil(counts["3"], "关闭预读后，停留在章末不能请求下一章")
    }

    private func cacheCounts() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/cache/stats")!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["counts"] as? [String: Int] ?? [:]
    }
}
