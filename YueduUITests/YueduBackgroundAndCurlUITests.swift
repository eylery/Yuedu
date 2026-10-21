import XCTest

final class YueduBackgroundAndCurlUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSlideTurnsAcrossChaptersChangesStyleAndRestoresPage() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        try require(app.buttons["shelf.continue"])
        app.buttons["shelf.continue"].tap()
        app.buttons["reader.settings"].tap()
        try require(app.navigationBars["阅读设置"])
        reveal(app.buttons["平移翻页"], in: app.scrollViews.firstMatch)
        app.buttons["平移翻页"].tap()
        app.buttons["完成"].tap()
        let page = app.staticTexts["reader.pageText"].firstMatch
        try require(page)
        let initialText = page.label
        let paper = app.otherElements["reader.pagedContent"]
        paper.swipeLeft()
        expect(page, predicate: NSPredicate(format: "label != %@", initialText))
        paper.swipeRight()
        expect(page, predicate: NSPredicate(format: "label == %@", initialText))
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expect(page, predicate: NSPredicate(format: "label != %@", initialText))
        XCTAssertTrue(yueduReadingInfo(app, identifier: "reader.pageInfo").contains("页"))
        app.buttons["reader.addBookmark"].tap()
        screenshot(app, "Horizontal slide second page")

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        try require(page)
        XCTAssertNotEqual(page.label, initialText)
        XCTAssertEqual(app.buttons["reader.addBookmark"].label, "移除此处书签")

        // Interactive swipe and edge taps both advance; crossing the final
        // paper opens the next chapter rather than an empty trailing page.
        paper.swipeLeft()
        for _ in 0..<8 {
            if yueduReadingInfo(app, identifier: "reader.chapterInfo").contains("第 2 章") { break }
            paper.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(yueduReadingInfo(app, identifier: "reader.chapterInfo").contains("第 2 章"))
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(yueduReadingInfo(app, identifier: "reader.chapterInfo").contains("第 1 章"))
        screenshot(app, "Reverse slide returns to previous chapter")

        app.buttons["reader.settings"].tap()
        let font = app.sliders["readingSettings.fontSize"]
        reveal(font, in: app.scrollViews.firstMatch)
        font.adjust(toNormalizedSliderPosition: 0.9)
        let night = app.buttons["readingSettings.theme.night"]
        reveal(night, in: app.scrollViews.firstMatch)
        night.tap()
        app.buttons["完成"].tap()
        try require(page)
        XCTAssertTrue(yueduReadingInfo(app, identifier: "reader.chapterInfo").contains("第 1 章"))
        screenshot(app, "Large type on dark paper")
        let savedText = page.label
        app.terminate()
        app.launch()
        app.buttons["shelf.continue"].tap()
        try require(page)
        XCTAssertEqual(page.label, savedText)

        XCUIDevice.shared.orientation = .landscapeLeft
        // Rotation screenshots otherwise capture the presentation transform
        // half-way through the UIKit animation, before paper repagination.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertGreaterThan(paper.frame.width, paper.frame.height)
        screenshot(app, "Landscape paper layout")
        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(nanoseconds: 1_000_000_000)
        app.buttons["reader.settings"].tap()
        reveal(app.buttons["上下滚动"], in: app.scrollViews.firstMatch)
        app.buttons["上下滚动"].tap()
        app.buttons["完成"].tap()
        try require(app.staticTexts["reader.text"])
        XCTAssertFalse(page.exists)
    }

    @MainActor
    func testSystemDownloadsWhileBackgroundThenParsesWithoutChapterNetwork() async throws {
        _ = try await fixture("/background/reset")
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        try require(app.tabBars.buttons["书源"])
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/background-source.json")
        alert.buttons["导入"].tap()
        try require(app.alerts["已导入 1 个书源"], timeout: 15)
        app.alerts["已导入 1 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("后台\n")
        let result = app.cells.staticTexts["后台下载手记"]
        try require(result, timeout: 15)
        result.tap()
        app.buttons["加入书架并阅读"].tap()
        try require(app.staticTexts["reader.text"], timeout: 15)
        app.buttons["reader.details"].tap()
        app.cells["bookDetail.online.2"].tap()
        XCUIDevice.shared.press(.home)
        let backgroundTime = Date().timeIntervalSince1970
        var completed: [[String: Any]] = []
        for _ in 0..<50 {
            let stats = try await fixture("/background/stats")
            completed = stats["completed"] as? [[String: Any]] ?? []
            if Set(completed.compactMap { $0["chapter"] as? Int }).count == 7 { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertEqual(Set(completed.compactMap { $0["chapter"] as? Int }).count, 7,
                       "The OS must finish every transfer while the reader is off screen.")
        if Set(completed.compactMap { $0["chapter"] as? Int }).count != 7 {
            app.activate()
            app.cells["bookDetail.online.4"].tap()
            let diagnostic = XCTAttachment(string: app.debugDescription)
            diagnostic.name = "Background download failure details"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            return
        }
        XCTAssertTrue(completed.contains { ($0["time"] as? Double ?? 0) > backgroundTime })
        XCTAssertNotEqual(app.state, .runningForeground)
        _ = try await fixture("/background/offline")
        app.activate()
        let complete = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "缓存完成")).firstMatch
        try require(complete, timeout: 25)
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已缓存 7 章")).firstMatch
        try require(summary)
        let finalStats = try await fixture("/background/stats")
        let counts = finalStats["completed"] as? [[String: Any]] ?? []
        XCTAssertEqual(counts.count, completed.count, "Foreground parsing must reuse the transferred files; OS transfer retries are allowed.")
        XCTAssertEqual(finalStats["denied"] as? Int, 0, "No chapter request may be attempted after returning to the foreground.")
        screenshot(app, "Background files parsed with chapter server offline")
        app.cells["bookDetail.contents"].tap()
        let last = app.cells["reader.chapter.6"]
        reveal(last, in: app.tables["reader.contentsList"])
        last.tap()
        let body = app.staticTexts["reader.text"]
        expect(body, predicate: NSPredicate(format: "label CONTAINS %@", "第7章的正文已由系统下载"))
        XCTAssertFalse(app.buttons["reader.retry"].exists)
        screenshot(app, "Last chapter readable offline after background download")
    }

    @MainActor
    private func require(_ element: XCUIElement, timeout: TimeInterval = 8) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing element: \(element)")
            throw NSError(domain: "YueduUITest", code: 1)
        }
    }

    @MainActor
    private func expect(_ element: XCUIElement, predicate: NSPredicate) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<6 {
            if element.isHittable { return }
            scrollView.swipeUp()
        }
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        // Capture the whole display: app-only capture can crop legacy-window
        // applications using portrait coordinates after a landscape rotation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fixture(_ path: String) async throws -> [String: Any] {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:8080" + path)!, timeoutInterval: 3)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "YueduFixture", code: 1)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
