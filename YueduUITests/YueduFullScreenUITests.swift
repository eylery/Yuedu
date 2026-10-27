import XCTest

final class YueduFullScreenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScrollFullScreenStatusBarProgressAndRelaunch() throws {
        let app = launchReader()
        let content = app.scrollViews["reader.content"]
        let info = app.staticTexts["reader.chapterInfo"]
        let pageInfo = app.staticTexts["reader.pageInfo"]
        XCTAssertFalse(info.exists)
        XCTAssertFalse(pageInfo.exists)
        XCTAssertFalse(app.staticTexts["reader.progress"].exists)
        let normalFrame = content.frame
        let settingsFrame = app.buttons["reader.settings"].frame
        let backFrame = app.buttons["reader.back"].frame
        XCTAssertFalse(app.buttons["reader.fullScreen"].exists)
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(
            forDuration: 0.1,
            thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        XCTAssertFalse(app.buttons["reader.back"].isHittable)
        XCTAssertEqual(content.frame, normalFrame)
        centerTap(content)
        app.buttons["reader.addBookmark"].tap()
        let textFrame = app.staticTexts["reader.text"].frame
        screenshot("Overlay scroll tools visible")
        centerTap(content)
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        XCTAssertEqual(content.frame, normalFrame)
        XCTAssertTrue(info.isHittable)
        XCTAssertTrue(pageInfo.isHittable)
        XCTAssertTrue(info.label.hasPrefix("第 1 章 · "))
        XCTAssertNotEqual(pageInfo.label, "— / — 页")
        XCTAssertGreaterThan(pageInfo.frame.minY, content.frame.maxY)
        let savedPageInfo = pageInfo.label
        let infoFrame = info.frame
        XCTAssertEqual(app.staticTexts["reader.text"].frame, textFrame)
        expectStatusBar(app, visible: true)
        screenshot("Full screen with status bar")

        centerTap(content)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        XCTAssertEqual(content.frame, normalFrame)
        XCTAssertEqual(app.staticTexts["reader.text"].frame, textFrame)
        XCTAssertEqual(app.buttons["reader.settings"].frame, settingsFrame)
        XCTAssertEqual(app.buttons["reader.back"].frame, backFrame)
        XCTAssertFalse(info.exists)
        XCTAssertFalse(pageInfo.exists)
        XCTAssertEqual(app.buttons["reader.addBookmark"].label, "移除此处书签")
        app.buttons["reader.settings"].tap()
        reveal(app.buttons["readingSettings.theme.white"], in: app)
        app.buttons["readingSettings.theme.white"].tap()
        let status = app.switches["readingSettings.fullScreenStatusBar"]
        reveal(status, in: app)
        status.tap()
        app.buttons["完成"].tap()
        screenshot("White reader chrome")
        centerTap(content)
        expectStatusBar(app, visible: false)
        XCTAssertEqual(pageInfo.label, savedPageInfo)
        XCTAssertEqual(info.frame, infoFrame)
        XCTAssertEqual(content.frame, normalFrame)
        XCTAssertEqual(app.staticTexts["reader.text"].frame, textFrame)
        screenshot("Full screen without status bar")
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(content.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        expectStatusBar(app, visible: false)
        XCTAssertEqual(pageInfo.label, savedPageInfo)
        centerTap(content)
        XCTAssertFalse(info.exists)
        XCTAssertFalse(pageInfo.exists)
        XCTAssertEqual(app.buttons["reader.addBookmark"].label, "移除此处书签")
        expectStatusBar(app, visible: true)
        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 5))
        expectStatusBar(app, visible: true)
    }

    @MainActor
    func testPagedFullScreenThemeRotationAndSettings() async throws {
        let app = launchReader()
        app.buttons["reader.settings"].tap()
        reveal(app.buttons["平移翻页"], in: app)
        app.buttons["平移翻页"].tap()
        reveal(app.buttons["readingSettings.theme.night"], in: app)
        app.buttons["readingSettings.theme.night"].tap()
        let fullScreen = app.switches["readingSettings.fullScreen"]
        reveal(fullScreen, in: app)
        fullScreen.tap()
        app.buttons["完成"].tap()
        let content = app.otherElements["reader.pagedContent"]
        let page = app.staticTexts["reader.pageText"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        expectStatusBar(app, visible: true)
        let initial = page.label
        let pageInfo = app.staticTexts["reader.pageInfo"]
        XCTAssertTrue(app.staticTexts["reader.chapterInfo"].isHittable)
        XCTAssertTrue(pageInfo.label.hasPrefix("1 / "))
        let initialPageInfo = pageInfo.label
        let fullScreenFrame = content.frame
        for _ in 0..<3 {
            centerTap(content)
            XCTAssertTrue(app.buttons["reader.settings"].isHittable)
            XCTAssertEqual(content.frame, fullScreenFrame)
            XCTAssertEqual(page.label, initial)
            XCTAssertFalse(pageInfo.exists)
            XCTAssertFalse(app.staticTexts["reader.chapterInfo"].exists)
            centerTap(content)
            XCTAssertFalse(app.buttons["reader.settings"].isHittable)
            XCTAssertTrue(pageInfo.isHittable)
            XCTAssertEqual(pageInfo.label, initialPageInfo)
            XCTAssertEqual(content.frame, fullScreenFrame)
            XCTAssertEqual(page.label, initial)
        }
        centerTap(content)
        screenshot("Overlay paged tools visible")
        app.buttons["reader.addBookmark"].tap()
        centerTap(content)
        content.swipeLeft()
        XCTAssertNotEqual(page.label, initial)
        let savedPage = page.label
        XCTAssertNotEqual(pageInfo.label, initialPageInfo)
        let savedPageInfo = pageInfo.label
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        XCTAssertEqual(page.label, savedPage)
        XCTAssertEqual(pageInfo.label, savedPageInfo)
        content.swipeRight()
        XCTAssertEqual(page.label, initial)
        screenshot("Night full screen status bar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThan(content.frame.width, content.frame.height)
        XCTAssertGreaterThan(content.frame.minX, app.frame.minX)
        XCTAssertLessThan(content.frame.maxX, app.frame.maxX)
        screenshot("Landscape full screen safe area")
        let landscapeFrame = content.frame
        let landscapePage = page.label
        centerTap(content)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        XCTAssertEqual(content.frame, landscapeFrame)
        XCTAssertEqual(page.label, landscapePage)
        screenshot("Overlay landscape tools visible")
        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(nanoseconds: 1_000_000_000)
        app.buttons["reader.settings"].tap()
        reveal(app.buttons["上下滚动"], in: app)
        app.buttons["上下滚动"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.scrollViews["reader.content"].isHittable)
        centerTap(app.scrollViews["reader.content"])
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        centerTap(app.scrollViews["reader.content"])
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
    }

    @MainActor
    private func launchReader() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 8))
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(app.buttons["reader.settings"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    func testScrollingEitherDirectionHidesToolsWithoutChangingTheSavedPreference() {
        let app = launchReader()
        let content = app.scrollViews["reader.content"]
        let frame = content.frame
        content.swipeUp()
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        XCTAssertFalse(app.buttons["reader.back"].isHittable)
        XCTAssertEqual(content.frame, frame)
        centerTap(content)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        content.swipeDown()
        XCTAssertFalse(app.buttons["reader.settings"].isHittable)
        XCTAssertEqual(content.frame, frame)
        screenshot("Scroll automatically hides reading tools")
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(app.buttons["reader.settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)
        XCTAssertFalse(app.buttons["reader.fullScreen"].exists)
    }

    @MainActor
    private func centerTap(_ content: XCUIElement) {
        content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            let scroll = app.scrollViews["readingSettings.content"]
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.85)).press(
                forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2))
            )
        }
        screenshot("Settings reveal failure")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Settings hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func expectStatusBar(_ app: XCUIApplication, visible: Bool) {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // iOS keeps empty status-bar containers after hiding the clock and
            // indicators. Check their content, including the system-owned bar.
            let bars = system.statusBars.allElementsBoundByIndex + app.statusBars.allElementsBoundByIndex
            return bars.contains { $0.descendants(matching: .any).count > 0 } == visible
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed {
            screenshot("Status bar assertion failure")
            let tree = XCTAttachment(string: system.debugDescription)
            tree.name = "System status bar hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertEqual(result, .completed)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Read chapter/page information where the user sees it: on the reading layer
/// after dismissing the overlaid controls, then restore the controls if needed.
@MainActor
func yueduReadingInfo(_ app: XCUIApplication, identifier: String? = nil) -> String {
    let toolsVisible = app.buttons["reader.settings"].isHittable
    if toolsVisible { yueduSetReadingTools(app, visible: false) }
    let chapter = app.staticTexts["reader.chapterInfo"]
    XCTAssertTrue(chapter.waitForExistence(timeout: 5))
    let result: String
    if let identifier {
        result = app.staticTexts[identifier].label
    } else {
        result = chapter.label + " · " + app.staticTexts["reader.pageInfo"].label
    }
    if toolsVisible {
        app.otherElements["reader.surface"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    return result
}

@MainActor
func yueduSetReadingTools(_ app: XCUIApplication, visible: Bool) {
    if app.buttons["reader.settings"].isHittable != visible {
        app.otherElements["reader.surface"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
