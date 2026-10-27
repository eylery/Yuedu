import XCTest

final class YueduOnlineSearchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func prepare(speed: Bool = false) async throws -> XCUIApplication {
        let path = speed ? "online-speed-sources.json" : "online-sources.json"
        let count = speed ? 5 : 3
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/\(path)")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/\(path)")
        alert.buttons["导入"].tap()
        guard app.alerts["已导入 \(count) 个书源"].waitForExistence(timeout: 12) else {
            XCTFail("测试书源导入未完成")
            return app
        }
        app.alerts["已导入 \(count) 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        return app
    }

    @MainActor
    private func assertStatus(_ app: XCUIApplication, contains text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts["search.status"])
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed)
        return result == .completed
    }

    @MainActor
    private func match(_ title: String, app: XCUIApplication) {
        app.buttons["search.options"].tap()
        app.buttons["匹配方式"].tap()
        app.buttons[title].tap()
    }

    @MainActor
    func testRetryPaginationMatchingVersionSelectionAndRead() async throws {
        let app = try await prepare()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日手记\n")
        guard assertStatus(app, contains: "1 个失败") else { return }
        XCTAssertEqual(app.tables["search.results"].cells.count, 2, "重复链接去重，同名同作者默认合并")
        app.buttons["search.failures"].tap()
        XCTAssertTrue(app.alerts["书源搜索情况"].waitForExistence(timeout: 3))
        app.alerts.buttons["重试失败书源"].tap()
        guard assertStatus(app, contains: "4 条收录") else { return }
        XCTAssertFalse(app.buttons["search.failures"].isHittable)
        app.buttons["search.more"].tap()
        guard assertStatus(app, contains: "5 条收录") else { return }
        app.tables["search.results"].swipeUp()
        app.buttons["search.more"].tap()
        let ended = app.buttons["search.more"]
        let exhausted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已展示全部结果"), object: ended)
        XCTAssertEqual(XCTWaiter.wait(for: [exhausted], timeout: 10), .completed)
        app.tables["search.results"].swipeDown()
        app.buttons["search.options"].tap()
        app.buttons["合并同名同作者"].tap()
        XCTAssertEqual(app.tables["search.results"].cells.count, 5)
        app.buttons["search.options"].tap()
        app.buttons["合并同名同作者"].tap()
        app.segmentedControls["search.match"].buttons["精确"].tap()
        XCTAssertEqual(app.tables["search.results"].cells.count, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 条收录")).firstMatch.exists)
        match("作者包含", app: app)
        XCTAssertTrue(app.cells.staticTexts["远山故事"].exists)
        XCTAssertFalse(app.cells.staticTexts["春日手记"].exists)
        app.buttons["search.options"].tap()
        app.buttons["结果排序"].tap()
        app.buttons["按书名排序"].tap()
        match("书名完全匹配", app: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Online search matching and merged versions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.cells.staticTexts["春日手记"].tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 3))
        app.cells["search.book.source.搜索测试·二号"].tap()
        XCTAssertEqual(app.cells["search.book.source.搜索测试·二号"].value as? String, "已选择")
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Search book and source selection"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
        app.buttons["加入书架并阅读"].tap()
        let body = app.staticTexts["reader.text"]
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "窗边的光"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 15), .completed)
    }

    @MainActor
    func testSourceGroupScopeHistoryPersistenceAndClear() async throws {
        let app = try await prepare()
        app.buttons["search.scope"].tap()
        app.buttons["清空选择"].tap()
        app.buttons["search.scope.groups"].tap()
        app.buttons["常用"].tap()
        app.buttons["选中当前列表"].tap()
        app.navigationBars["搜索范围"].buttons["应用"].tap()
        XCTAssertTrue(app.buttons["search.scope"].label.contains("2 个书源"))
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日\n")
        guard assertStatus(app, contains: "3 条收录") else { return }
        XCTAssertFalse(app.buttons["search.failures"].isHittable)
        app.buttons["search.scope"].tap()
        app.buttons["清空选择"].tap()
        app.cells["search.scope.搜索测试·二号"].tap()
        app.navigationBars["搜索范围"].buttons["应用"].tap()
        guard assertStatus(app, contains: "1 条收录") else { return }
        XCTAssertEqual(app.tables["search.results"].cells.count, 1)
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        XCTAssertTrue(app.buttons["search.recent.春日"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["search.scope"].label.contains("1 个书源"))
        app.buttons["search.recent.春日"].tap()
        guard assertStatus(app, contains: "1 条收录") else { return }
        XCTAssertEqual(app.searchFields["搜索书名、作者"].value as? String, "春日")
        app.buttons["search.history"].tap()
        app.buttons["清空搜索历史"].tap()
        app.buttons["search.history"].tap()
        XCTAssertTrue(app.buttons["暂无搜索记录"].exists)
    }

    @MainActor
    func testFastResultCanOpenWhileSlowSourcesRunAndSavedBookResumes() async throws {
        let app = try await prepare(speed: true)
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("春日手记")
        app.buttons["search.submit"].tap()
        let result = app.cells.staticTexts["春日手记"]
        guard result.waitForExistence(timeout: 8) else {
            XCTFail("前三个书源慢响应不应挡住其他站点的第四个书源")
            return
        }
        XCTAssertTrue(app.buttons["search.stop"].isHittable)
        app.segmentedControls["search.match"].buttons["精确"].tap()
        XCTAssertTrue(result.isHittable)
        result.tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 3))
        app.buttons["search.book.read"].tap()
        let body = app.staticTexts["reader.text"]
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "窗边的光"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 12), .completed)
        app.buttons["reader.nextChapter"].tap()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "雨停了"), object: body)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 10), .completed)
        app.buttons["reader.back"].tap()
        XCTAssertEqual(app.buttons["search.book.read"].label, "继续阅读")
        app.buttons["search.book.read"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "雨停了"), object: body)], timeout: 5), .completed)
        app.buttons["reader.back"].tap()
        app.navigationBars["书籍详情"].buttons.element(boundBy: 0).tap()
        search.tap()
        let value = search.value as? String ?? ""
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        XCTAssertTrue(app.buttons["search.recent.春日手记"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.tables["search.results"].cells.count, 0)
        XCTAssertFalse(app.buttons["search.stop"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Recent searches after clearing query"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFailedCatalogCanChooseAnotherSourceAndSaveWithoutLeavingDetails() async throws {
        let app = try await prepare()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("目录失败\n")
        guard assertStatus(app, contains: "1 个失败") else { return }
        app.cells.staticTexts["春日手记"].tap()
        app.cells["search.book.source.搜索测试·一号"].tap()
        app.buttons["search.book.read"].tap()
        let failure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "加载失败"),
            object: app.staticTexts["search.book.status"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [failure], timeout: 10), .completed)
        XCTAssertTrue(app.cells["search.book.source.搜索测试·二号"].isHittable)
        app.cells["search.book.source.搜索测试·二号"].tap()
        app.buttons["search.book.save"].tap()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已在书架"),
            object: app.buttons["search.book.save"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["书籍详情"].exists)
        app.buttons["search.book.read"].tap()
        let reading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "窗边的光"),
            object: app.staticTexts["reader.text"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 10), .completed)
    }

    @MainActor
    func testSameBookMergesAuthorVariantsAndSourceRecordsExpandWithoutLosingSelection() async throws {
        let app = try await prepare()
        let search = app.searchFields["搜索书名、作者"]
        search.tap()
        search.typeText("西游记\n")
        guard assertStatus(app, contains: "9 条收录") else { return }
        XCTAssertEqual(app.tables["search.results"].cells.count, 2, "改编署名应保留为另一本书")
        let book = app.tables["search.results"].cells.containing(
            NSPredicate(format: "label CONTAINS %@", "吴承恩")
        ).firstMatch
        book.tap()
        let table = app.tables["search.book.details"]
        XCTAssertTrue(table.waitForExistence(timeout: 3))
        XCTAssertEqual(table.cells.count, 4, "简介、两个书源和试读入口，同源记录默认收起")
        let first = app.cells["search.book.source.搜索测试·一号"]
        first.tap()
        XCTAssertEqual(table.cells.count, 11, "展开一号书源的七条收录")
        let secondRecord = app.cells["search.book.record.搜索测试·一号.2"]
        for _ in 0..<4 where !secondRecord.isHittable { table.swipeUp() }
        secondRecord.tap()
        XCTAssertEqual(secondRecord.value as? String, "已选择")
        for _ in 0..<4 where !first.isHittable { table.swipeDown() }
        first.tap()
        XCTAssertEqual(table.cells.count, 4)
        XCTAssertTrue(app.staticTexts["search.book.status"].label.contains("收录 2"))
        app.cells["search.book.source.搜索测试·二号"].tap()
        XCTAssertEqual(app.cells["search.book.source.搜索测试·二号"].value as? String, "已选择")
        first.tap()
        XCTAssertEqual(secondRecord.value as? String, "已选择", "切换书源后应记住尚未入库的选择")
        first.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One book with collapsed source records"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["search.book.save"].tap()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已在书架"), object: app.buttons["search.book.save"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.buttons["search.book.read"].tap()
        let reading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "选中的第二条收录正文"), object: app.staticTexts["reader.text"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 10), .completed)
        app.buttons["reader.back"].tap()
        app.navigationBars["书籍详情"].buttons.element(boundBy: 0).tap()
        book.tap()
        XCTAssertEqual(table.cells.count, 4)
        XCTAssertEqual(app.buttons["search.book.read"].label, "继续阅读")
        first.tap()
        XCTAssertEqual(app.cells["search.book.record.搜索测试·一号.2"].value as? String, "已选择")
    }

    @MainActor
    func testPreviewDoesNotSaveAndLibraryQueryCarriesIntoOnlineSearch() async throws {
        let app = try await prepare()
        app.navigationBars["搜索书籍"].buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["搜索书架"].tap()
        let shelfSearch = app.searchFields["书名、作者或内容简介"]
        shelfSearch.tap()
        shelfSearch.typeText("西游记")
        app.buttons["shelf.searchOnline"].tap()
        XCTAssertEqual(app.searchFields["搜索书名、作者"].value as? String, "西游记")
        guard assertStatus(app, contains: "9 条收录") else { return }
        app.tables["search.results"].cells.containing(NSPredicate(format: "label CONTAINS %@", "吴承恩")).firstMatch.tap()
        let table = app.tables["search.book.details"]
        let preview = app.cells["search.book.preview"]
        for _ in 0..<4 where !preview.isHittable { table.swipeUp() }
        preview.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "试读已就绪"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(app.buttons["search.book.save"].label, "加入书架")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Catalog and first chapter preview before saving"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.tabBars.buttons["我的"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertEqual(app.buttons["search.book.save"].label, "加入书架")
        app.buttons["search.book.save"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已在书架"), object: app.buttons["search.book.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        app.buttons["search.book.read"].tap()
        XCTAssertTrue(app.staticTexts["reader.text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reader.text"].label.contains("收录正文"))
    }

}
