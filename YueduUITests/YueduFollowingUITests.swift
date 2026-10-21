import XCTest

final class YueduFollowingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testUpdateBadgePauseRestoreAndReadNewChapter() async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/polish/reset")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/polish-sources.json")
        alert.buttons["导入"].tap()
        XCTAssertTrue(app.alerts["已导入 2 个书源"].waitForExistence(timeout: 12))
        app.alerts["已导入 2 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日\n")
        let result = app.cells.containing(.staticText, identifier: "春日手记").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        result.tap()
        app.buttons["加入书架并阅读"].tap()
        XCTAssertTrue(app.staticTexts["reader.text"].waitForExistence(timeout: 12))
        app.buttons["reader.back"].tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf.following"].tap()
        XCTAssertTrue(app.navigationBars["追更管理"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["following.autoCheck"].value as? String, "0")
        app.buttons["following.check"].tap()
        let updated = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 章未读更新")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "最新：第三章 晚风")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Following updates and latest chapter"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["following.check"].tap()
        let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新增 0 章")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 15))
        XCTAssertTrue(updated.exists)
        app.tables["following.list"].buttons["有更新"].tap()
        let book = app.cells["following.book.春日手记"]
        XCTAssertTrue(book.exists)
        book.swipeLeft()
        app.buttons["暂停追更"].tap()
        app.tables["following.list"].buttons["已暂停"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 3))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["shelf.following"].tap()
        app.tables["following.list"].buttons["已暂停"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 3))
        XCTAssertTrue(updated.exists)
        book.swipeLeft()
        app.buttons["开始追更"].tap()
        app.tables["following.list"].buttons["有更新"].tap()
        book.tap()
        XCTAssertTrue(app.buttons["reader.nextChapter"].waitForExistence(timeout: 5))
        app.buttons["reader.nextChapter"].tap()
        let second = app.staticTexts["reader.chapterTitle"]
        let secondReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "第二章"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [secondReady], timeout: 12), .completed)
        app.buttons["reader.nextChapter"].tap()
        let text = app.staticTexts["reader.text"]
        let thirdReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "晚风拂过书页"), object: text)
        XCTAssertEqual(XCTWaiter.wait(for: [thirdReady], timeout: 12), .completed)
        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.staticTexts["暂时没有未读更新"].waitForExistence(timeout: 5))
    }
}
