import XCTest

final class YueduTypographyUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testTypographyAppliesToBothReadersPersistsAndResetsIndependently() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 8))
        app.buttons["shelf.continue"].tap()
        let body = app.staticTexts["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 8))
        let originalText = body.label
        let originalWidth = body.frame.width
        let content = app.scrollViews["reader.content"]
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(
            forDuration: 0.1, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.2
        )
        app.buttons["reader.addBookmark"].tap()
        app.buttons["reader.settings"].tap()
        openTypography(app)
        app.buttons["typography.font"].tap()
        app.buttons["系统黑体"].tap()
        app.segmentedControls["typography.bold"].buttons["加粗"].tap()
        adjust(app, "fontSize", to: 0.6)
        let savedSize = app.staticTexts["typography.fontSize.value"].label
        adjust(app, "lineSpacing", to: 0.3)
        adjust(app, "paragraphSpacing", to: 0.7)
        adjust(app, "characterSpacing", to: 0.5)
        let controls = app.scrollViews["typography.controls"]
        reveal(app.switches["typography.indent"], in: controls)
        app.switches["typography.indent"].tap()
        reveal(app.segmentedControls["typography.alignment"], in: controls)
        app.segmentedControls["typography.alignment"].buttons["两端对齐"].tap()
        reveal(app.segmentedControls["typography.titleAlignment"], in: controls)
        app.segmentedControls["typography.titleAlignment"].buttons["标题居中"].tap()
        adjust(app, "horizontalMargin", to: 0.7)
        adjust(app, "topMargin", to: 0.4)
        adjust(app, "bottomMargin", to: 0.5)
        screenshot("Typography spacing and margins preview")
        app.navigationBars["字体与排版"].buttons["BackButton"].tap()
        let settingsScroll = app.scrollViews["readingSettings.content"]
        reveal(app.buttons["readingSettings.theme.night"], in: settingsScroll)
        app.buttons["readingSettings.theme.night"].tap()
        app.buttons["完成"].tap()
        XCTAssertEqual(body.label, originalText)
        XCTAssertLessThan(body.frame.width, originalWidth - 20)
        XCTAssertEqual(app.buttons["reader.addBookmark"].label, "移除此处书签")
        screenshot("Typography scroll reader")
        app.buttons["reader.settings"].tap()
        reveal(app.buttons["平移翻页"], in: settingsScroll)
        app.buttons["平移翻页"].tap()
        app.buttons["完成"].tap()
        let page = app.staticTexts["reader.pageText"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let pages = app.otherElements["reader.pagedContent"]
        let beforeTurn = page.label
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let turn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", beforeTurn), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [turn], timeout: 8), .completed)
        let savedPage = page.label
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertEqual(page.label, savedPage)
        screenshot("Typography paged reader after relaunch")
        app.buttons["reader.fullScreen"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(pages.frame.width, pages.frame.height)
        XCTAssertFalse(page.label.isEmpty)
        screenshot("Typography full screen landscape")
        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(nanoseconds: 1_000_000_000)
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["reader.settings"].tap()
        openTypography(app)
        XCTAssertTrue(app.buttons["typography.font"].label.contains("系统黑体"))
        XCTAssertTrue(app.segmentedControls["typography.bold"].buttons["加粗"].isSelected)
        let size = app.sliders["typography.fontSize"]
        reveal(size, in: controls)
        XCTAssertEqual(app.staticTexts["typography.fontSize.value"].label, savedSize)
        reveal(app.buttons["typography.presets"], in: controls)
        app.buttons["typography.presets"].tap()
        app.buttons["紧凑"].tap()
        reveal(app.buttons["typography.reset"], in: controls)
        app.buttons["typography.reset"].tap()
        app.alerts["恢复默认排版"].buttons["取消"].tap()
        app.buttons["typography.reset"].tap()
        app.alerts["恢复默认排版"].buttons["恢复"].tap()
        reveal(app.buttons["typography.font"], in: controls)
        XCTAssertTrue(app.buttons["typography.font"].label.contains("宋体"))
        XCTAssertTrue(app.segmentedControls["typography.bold"].buttons["普通"].isSelected)
        screenshot("Typography default font settings")
        app.navigationBars["字体与排版"].buttons["BackButton"].tap()
        reveal(app.buttons["readingSettings.theme.night"], in: settingsScroll)
        XCTAssertTrue(app.buttons["readingSettings.theme.night"].isSelected)
        app.buttons["完成"].tap()
        XCTAssertTrue(page.exists)
    }

    @MainActor
    private func openTypography(_ app: XCUIApplication) {
        let button = app.buttons["readingSettings.typography"]
        reveal(button, in: app.scrollViews["readingSettings.content"])
        button.tap()
        XCTAssertTrue(app.navigationBars["字体与排版"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func adjust(_ app: XCUIApplication, _ id: String, to position: CGFloat) {
        let slider = app.sliders["typography.\(id)"]
        reveal(slider, in: app.scrollViews["typography.controls"])
        slider.adjust(toNormalizedSliderPosition: position)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<12 {
            if element.isHittable { return }
            let above = element.frame.midY < scroll.frame.minY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: above ? 0.2 : 0.85)).press(
                forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: above ? 0.85 : 0.2))
            )
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
