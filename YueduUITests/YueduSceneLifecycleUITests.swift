import XCTest

final class YueduSceneLifecycleUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testExternalDocumentOpensOnColdLaunchAndWhileSettingsArePresented() throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("Opening external URLs through XCTest requires iOS 16.4.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coldURL = directory.appendingPathComponent("场景冷启动.txt")
        let warmURL = directory.appendingPathComponent("场景再次打开.txt")
        try "第一章 初见\n冷启动也能导入书籍。".write(to: coldURL, atomically: true, encoding: .utf8)
        try "第一章 重逢\n正在运行时也能导入书籍。".write(to: warmURL, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []

        app.open(coldURL)
        let body = app.staticTexts["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(body.label.contains("冷启动也能导入书籍"))
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 3))

        app.open(warmURL)
        let imported = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "正在运行时也能导入书籍"), object: body
        )
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 10), .completed)
        XCTAssertFalse(app.navigationBars["阅读设置"].exists)

        app.buttons["reader.back"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["book.场景冷启动"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["book.场景再次打开"].exists)
    }

    @MainActor
    func testReaderSurvivesBackgroundAndRestoresProgressAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["shelf.continue"].waitForExistence(timeout: 10))
        app.buttons["shelf.continue"].tap()
        app.buttons["reader.nextChapter"].tap()
        let chapter = app.staticTexts["reader.chapterTitle"].label

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, chapter)
        XCTAssertTrue(app.buttons["reader.settings"].isHittable)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.continue"].tap()
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, chapter)
    }
}
