import XCTest

/// Integration prerequisite: run `python3 scripts/demo_source_server.py` from
/// the repository root before this test. The test explicitly skips when the
/// localhost fixture is unavailable; it never substitutes a fake search result.
final class SourceFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testImportSearchReadAndRestoreCachedChapterWithSourceDisabled() async throws {
        try await requireLocalFixture()
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()

        let sourceNavigation = app.navigationBars["书源"]
        XCTAssertTrue(sourceNavigation.waitForExistence(timeout: 5))
        sourceNavigation.buttons.firstMatch.tap()
        let importAction = app.buttons["从网址导入"]
        XCTAssertTrue(importAction.waitForExistence(timeout: 3))
        importAction.tap()
        let importAlert = app.alerts["从网址导入"]
        XCTAssertTrue(importAlert.waitForExistence(timeout: 3))
        let urlField = importAlert.textFields.firstMatch
        urlField.tap()
        urlField.typeText("http://localhost:8080/source.json")
        importAlert.buttons["导入"].tap()

        let success = app.alerts["已导入 1 个书源"]
        XCTAssertTrue(success.waitForExistence(timeout: 12), "Local source import should finish successfully.")
        success.buttons["完成"].tap()
        let sourceSwitch = app.switches["启用本地测试书源"]
        XCTAssertTrue(sourceSwitch.waitForExistence(timeout: 3))
        XCTAssertEqual(sourceSwitch.value as? String, "1")
        attachScreenshot(app, name: "Imported local book source")

        app.tabBars.buttons["发现"].tap()
        let explore = app.buttons["discovery.searchBooks"]
        XCTAssertTrue(explore.waitForExistence(timeout: 3))
        explore.tap()
        let search = app.searchFields["搜索书名、作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("春日\n")
        let result = app.cells.staticTexts["春日手记"]
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        result.tap()
        let read = app.buttons["加入书架并阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 3))
        read.tap()

        let chapterTitle = app.staticTexts["reader.chapterTitle"]
        let body = app.staticTexts["reader.text"]
        assertLabel(chapterTitle, contains: "第一章 春日读书", timeout: 12)
        assertLabel(body, contains: "窗边的光落在书页上", timeout: 12)
        app.buttons["reader.nextChapter"].tap()
        assertLabel(chapterTitle, contains: "第二章 雨后散步", timeout: 12)
        assertLabel(body, contains: "雨停了", timeout: 12)
        attachScreenshot(app, name: "Downloaded second chapter")

        // Disabling the source makes SourceEngine reject any uncached request.
        // A successful read after process restart therefore exercises the disk
        // cache rather than relying on the still-running development server.
        app.buttons["reader.back"].tap()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 3))
        app.tabBars.buttons["书源"].tap()
        XCTAssertTrue(sourceSwitch.waitForExistence(timeout: 3))
        sourceSwitch.tap()
        assertSwitchDisabled(sourceSwitch)
        attachScreenshot(app, name: "Source disabled before offline restore")

        app.terminate()
        app.launchArguments = []
        app.launch()
        let resume = app.buttons["shelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(resume.label.contains("春日手记"), "The most recently read online book should be restored on the shelf.")
        attachScreenshot(app, name: "Online book persisted on bookshelf")
        resume.tap()
        assertLabel(chapterTitle, contains: "第二章 雨后散步", timeout: 5)
        assertLabel(body, contains: "雨停了", timeout: 5)
        XCTAssertFalse(app.buttons["reader.retry"].exists)
        attachScreenshot(app, name: "Cached chapter restored with source disabled")
    }

    @MainActor
    func testMixedImportKeepsScriptedTextSourcesExcludesComicsAndPreservesConfiguration() async throws {
        try await requireLocalFixture(path: "/mixed-sources.json")
        continueAfterFailure = false
        let supportedName = "混合测试·规则受支持"
        let scriptedName = "混合测试·脚本书源"
        let excludedName = "混合测试·漫画书源"
        let rawScriptMarker = "raw_script_marker_should_not_appear"
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        let sourceNavigation = app.navigationBars["书源"]
        XCTAssertTrue(sourceNavigation.waitForExistence(timeout: 5))
        sourceNavigation.buttons["添加与管理书源"].tap()
        let importAction = app.buttons["从网址导入"]
        XCTAssertTrue(importAction.waitForExistence(timeout: 3))
        importAction.tap()
        let importAlert = app.alerts["从网址导入"]
        XCTAssertTrue(importAlert.waitForExistence(timeout: 3))
        importAlert.textFields.firstMatch.tap()
        importAlert.textFields.firstMatch.typeText("http://localhost:8080/mixed-sources.json")
        importAlert.buttons["导入"].tap()

        let result = app.alerts["已导入 2 个书源"]
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        let resultSummary = result.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保留 2 个文字书源")).firstMatch
        assertLabel(resultSummary, contains: "2 个配置通过检查", timeout: 3)
        assertLabel(resultSummary, contains: "1 个漫画、有声、视频等非文字源已排除", timeout: 3)
        assertLabel(resultSummary, contains: "1 项配置无效，已跳过", timeout: 3)
        assertLabel(resultSummary, contains: "不代表网站已联网验证", timeout: 3)
        let detailsButton = result.buttons["查看详情"]
        let detailsReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: detailsButton)
        guard XCTWaiter.wait(for: [detailsReady], timeout: 5) == .completed else {
            XCTFail("The import report action must be visible and hittable before tapping.")
            return
        }
        detailsButton.tap()

        let report = app.tables["sources.importReport"]
        guard report.waitForExistence(timeout: 5) else {
            attachScreenshot(app, name: "Import report did not open after detail action")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Accessibility hierarchy after detail action"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("The import report did not open; stop here instead of issuing gestures to a missing table.")
            return
        }
        XCTAssertTrue(app.navigationBars["导入详情"].exists)
        XCTAssertFalse(report.cells["sources.importReport.issue.2"].exists, "Valid JavaScript text sources must not be reported as incompatible.")
        let invalidRow = report.cells["sources.importReport.issue.3"]
        let invalidReason = invalidRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已跳过")).firstMatch
        reveal(invalidReason, in: report)
        assertLabel(invalidReason, contains: "缺少有效的书源名称", timeout: 3)
        XCTAssertTrue(invalidReason.isHittable, "Invalid entries should be individually explained, including the skipped reason.")
        let excludedRow = report.cells["sources.importReport.issue.4"]
        let excludedReason = excludedRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已排除")).firstMatch
        let excludedTitle = excludedRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", excludedName)).firstMatch
        reveal(excludedReason, in: report)
        assertLabel(excludedTitle, contains: excludedName, timeout: 3)
        assertLabel(excludedReason, contains: "非文字书源", timeout: 3)
        XCTAssertTrue(excludedReason.isHittable, "Non-text sources should be explicitly reported as excluded.")
        XCTAssertFalse(report.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", rawScriptMarker)).firstMatch.exists)
        attachScreenshot(app, name: "Mixed import report with excluded and skipped entries")
        app.navigationBars["导入详情"].buttons.firstMatch.tap()

        let supportedSwitch = app.switches["启用\(supportedName)"]
        let scriptedSwitch = app.switches["启用\(scriptedName)"]
        XCTAssertTrue(supportedSwitch.waitForExistence(timeout: 3))
        XCTAssertTrue(supportedSwitch.isEnabled)
        XCTAssertEqual(supportedSwitch.value as? String, "1")
        XCTAssertTrue(scriptedSwitch.waitForExistence(timeout: 3))
        XCTAssertTrue(scriptedSwitch.isEnabled, "JavaScript text sources should be usable by the Legado runtime.")
        XCTAssertEqual(scriptedSwitch.value as? String, "1")
        XCTAssertFalse(app.tables.cells.staticTexts[excludedName].exists, "Excluded comic sources must not enter the source list.")
        let sourceCount = app.staticTexts["sources.count"]
        assertLabel(sourceCount, contains: "2 个已启用", timeout: 3)
        attachScreenshot(app, name: "Two enabled text sources after comic exclusion")

        // The summary alert is transient, but the report remains reachable for
        // the rest of the session through the source management menu.
        sourceNavigation.buttons["添加与管理书源"].tap()
        let lastReport = app.buttons["上次导入详情"]
        XCTAssertTrue(lastReport.waitForExistence(timeout: 3))
        XCTAssertTrue(lastReport.isEnabled)
        lastReport.tap()
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        XCTAssertTrue(report.cells["sources.importReport.summary"].staticTexts["已导入 2 个书源"].exists)
        app.navigationBars["导入详情"].buttons.firstMatch.tap()

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        XCTAssertTrue(supportedSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(supportedSwitch.value as? String, "1")
        XCTAssertTrue(supportedSwitch.isEnabled)
        XCTAssertTrue(scriptedSwitch.waitForExistence(timeout: 3))
        XCTAssertTrue(scriptedSwitch.isEnabled)
        XCTAssertEqual(scriptedSwitch.value as? String, "1")
        assertLabel(sourceCount, contains: "2 个已启用", timeout: 3)

        // Script text is intentionally available only when explicitly editing
        // the configuration, and unknown metadata must survive the round trip.
        app.tables.cells.staticTexts[scriptedName].tap()
        let editor = app.textViews["书源 JSON 编辑器"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let savedJSON = editor.value as? String ?? ""
        XCTAssertTrue(savedJSON.contains(rawScriptMarker))
        XCTAssertTrue(savedJSON.contains("mixed-import-preserves-metadata"))
        let login = app.buttons["sources.editor.login"]
        let explore = app.buttons["sources.editor.explore"]
        XCTAssertTrue(login.exists)
        XCTAssertTrue(login.isEnabled)
        XCTAssertTrue(explore.exists)
        XCTAssertTrue(explore.isEnabled)
        XCTAssertFalse(app.buttons["sources.editor.compatibility"].exists)
        attachScreenshot(app, name: "Script configuration and login exploration actions preserved after restart")
        login.tap()
        let account = app.textFields["sources.loginField.测试账号"]
        XCTAssertTrue(account.waitForExistence(timeout: 8))
        account.tap()
        account.typeText("local-fixture")
        app.navigationBars["登录与设置"].buttons["sources.loginSave"].tap()
        assertLabel(app.staticTexts["sources.loginStatus"], contains: "已保存", timeout: 8)
        attachScreenshot(app, name: "Legado source login settings saved")
        app.navigationBars["登录与设置"].buttons.firstMatch.tap()
        login.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertEqual(account.value as? String, "local-fixture")
        let apply = app.buttons["sources.loginAction.应用设置"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        apply.tap()
        assertLabel(app.staticTexts["sources.loginStatus"], contains: "设置已应用：local-fixture", timeout: 8)
        app.navigationBars["登录与设置"].buttons.firstMatch.tap()
        explore.tap()
        let category = app.cells.staticTexts["本地故事"]
        XCTAssertTrue(category.waitForExistence(timeout: 8))
        category.tap()
        XCTAssertTrue(app.cells.staticTexts["春日手记"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Legado explore category displays local book")
    }

    private func requireLocalFixture(path: String = "/source.json") async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: URL(string: "http://localhost:8080\(path)")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  String(data: data, encoding: .utf8)?.contains("bookSourceName") == true else {
                throw XCTSkip("Local source fixture is unavailable. Run: python3 scripts/demo_source_server.py")
            }
        } catch let skip as XCTSkip { throw skip }
        catch {
            throw XCTSkip("Local source fixture is unavailable. Run: python3 scripts/demo_source_server.py. \(error.localizedDescription)")
        }
    }

    @MainActor
    func testCatalogUpdateBulkCacheSearchAndSourceSwitch() async throws {
        continueAfterFailure = false
        try await requireLocalFixture(path: "/polish-sources.json")
        _ = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/polish/reset")!)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["书源"].waitForExistence(timeout: 10))
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let importAlert = app.alerts["从网址导入"]
        XCTAssertTrue(importAlert.waitForExistence(timeout: 3))
        importAlert.textFields.firstMatch.tap()
        importAlert.textFields.firstMatch.typeText("http://localhost:8080/polish-sources.json")
        importAlert.buttons["导入"].tap()
        XCTAssertTrue(app.alerts["已导入 2 个书源"].waitForExistence(timeout: 12))
        app.alerts["已导入 2 个书源"].buttons["完成"].tap()
        app.tabBars.buttons["发现"].tap()
        app.buttons["discovery.searchBooks"].tap()
        let search = app.searchFields["搜索书名、作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("春日\n")
        let original = app.cells.containing(.staticText, identifier: "春日手记").firstMatch
        guard original.waitForExistence(timeout: 15) else {
            XCTFail("The local fixture must produce a selectable book.")
            return
        }
        original.tap()
        app.buttons["加入书架并阅读"].tap()
        assertLabel(app.staticTexts["reader.text"], contains: "窗边的光", timeout: 12)
        app.buttons["reader.addBookmark"].tap()
        app.buttons["reader.nextChapter"].tap()
        assertLabel(app.staticTexts["reader.chapterTitle"], contains: "第二章", timeout: 12)
        XCTAssertFalse(app.buttons["reader.nextChapter"].isEnabled)
        app.buttons["reader.details"].tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 3))
        app.cells["bookDetail.online.0"].tap()
        let updated = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新增 1 章")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 12))
        app.navigationBars["书籍详情"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["reader.nextChapter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reader.nextChapter"].isEnabled)
        app.buttons["reader.details"].tap()
        app.cells["bookDetail.online.2"].tap()
        let complete = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "缓存完成")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Updated catalog and all chapters cached")

        app.cells["bookDetail.contents"].tap()
        let chapterSearch = app.searchFields["搜索章节名或章序号"]
        XCTAssertTrue(chapterSearch.waitForExistence(timeout: 3))
        chapterSearch.tap()
        chapterSearch.typeText("第二章")
        let chapter = app.cells["reader.chapter.1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        XCTAssertFalse(app.cells["reader.chapter.0"].exists)
        chapter.tap()
        assertLabel(app.staticTexts["reader.chapterTitle"], contains: "第二章", timeout: 5)
        let details = app.buttons["reader.details"]
        let readerVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: details
        )
        guard XCTWaiter.wait(for: [readerVisible], timeout: 5) == .completed else {
            XCTFail("Selecting a search result must dismiss the whole contents sheet.")
            return
        }
        details.tap()
        app.cells["bookDetail.online.1"].tap()
        let alternative = app.cells.staticTexts["春日手记"]
        XCTAssertTrue(alternative.waitForExistence(timeout: 12))
        alternative.tap()
        XCTAssertTrue(app.navigationBars["换源对比"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.cells["sourceSwitch.chapter"].staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第二章")).firstMatch.exists)
        let confirm = app.buttons["sourceSwitch.confirm"]
        XCTAssertFalse(confirm.isEnabled)
        let preview = app.cells["sourceSwitch.preview"]
        for _ in 0..<5 where !preview.isHittable { app.tables["sourceSwitch.list"].swipeUp() }
        preview.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
            XCTFail("Source switch must verify chapter text before saving")
            return
        }
        confirm.tap()
        assertLabel(app.staticTexts["reader.chapterTitle"], contains: "第二章", timeout: 12)
        assertLabel(app.staticTexts["reader.text"], contains: "雨停了", timeout: 12)
        attachScreenshot(app, name: "Alternate source resumes matched chapter")

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["书源"].tap()
        for name in ["打磨测试·原书源", "打磨测试·备用源"] {
            let toggle = app.switches["启用\(name)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            toggle.tap()
        }
        app.tabBars.buttons["书架"].tap()
        app.buttons["shelf.continue"].tap()
        assertLabel(app.staticTexts["reader.text"], contains: "雨停了", timeout: 5)
        app.buttons["reader.back"].tap()
        app.tabBars.buttons["我的"].tap()
        app.buttons["我的书签"].tap()
        let bookmark = app.cells.staticTexts["第一章 春日读书"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 3))
        bookmark.tap()
        assertLabel(app.staticTexts["reader.text"], contains: "窗边的光", timeout: 5)
        attachScreenshot(app, name: "Original bookmark and cached text preserved after switch")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<5 {
            if element.isHittable { return }
            scrollView.swipeUp()
        }
    }

    @MainActor
    private func assertLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, "Expected visible text: \(text)")
    }

    @MainActor
    private func assertSwitchDisabled(_ element: XCUIElement) {
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
