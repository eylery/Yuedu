import XCTest

final class YueduSourceToolsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testBatchGroupingRealChecksFailureFilteringAndPersistence() async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:8080/source-tools.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["从网址导入"].tap()
        let alert = app.alerts["从网址导入"]
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("http://localhost:8080/source-tools.json")
        alert.buttons["导入"].tap()
        XCTAssertTrue(app.alerts["已导入 3 个书源"].waitForExistence(timeout: 12))
        app.alerts["已导入 3 个书源"].buttons["完成"].tap()
        app.navigationBars["书源"].buttons["管理"].tap()
        app.buttons["sources.selectAll"].tap()
        app.buttons["sources.batch.group"].tap()
        app.buttons["新建分组并移入"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("常用网文")
        app.alerts.buttons["保存"].tap()
        app.buttons["sources.batch.check"].tap()
        let keyword = app.textFields["sourceChecks.keyword"]
        XCTAssertTrue(keyword.waitForExistence(timeout: 5))
        keyword.tap()
        if let value = keyword.value as? String { keyword.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        keyword.typeText("春日")
        app.buttons["搜索 → 目录 → 首章"].tap()
        app.buttons["sourceChecks.start"].tap()
        let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检测完成 · 3 个已检测")).firstMatch
        guard completed.waitForExistence(timeout: 30) else { XCTFail("检测未完成"); return }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检测通过 · 首章正文")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "检测失败 · 搜索")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无搜索结果")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Source tools real checks"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["书源检测"].buttons["BackButton"].tap()
        app.navigationBars["书源"].buttons["完成"].tap()
        XCTAssertEqual(app.switches["启用工具测试·正常"].value as? String, "0", "Testing must not enable a disabled source")
        app.buttons["sources.groups"].tap()
        app.buttons["常用网文"].tap()
        XCTAssertTrue(app.cells["sources.row.工具测试·正常"].exists)
        app.buttons["sources.filter"].tap()
        app.buttons["检测失败"].tap()
        XCTAssertTrue(app.cells["sources.row.工具测试·故障"].exists)
        XCTAssertFalse(app.cells["sources.row.工具测试·正常"].exists)
        app.navigationBars["书源"].buttons["管理"].tap()
        app.buttons["sources.selectAll"].tap()
        app.buttons["sources.batch.status"].tap()
        app.buttons["停用所选"].tap()
        app.navigationBars["书源"].buttons["完成"].tap()
        XCTAssertEqual(app.switches["启用工具测试·故障"].value as? String, "0")
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.buttons["sources.filter"].tap()
        app.buttons["检测失败"].tap()
        XCTAssertTrue(app.cells["sources.row.工具测试·故障"].exists)
        XCTAssertEqual(app.switches["启用工具测试·故障"].value as? String, "0")
        app.navigationBars["书源"].buttons["管理"].tap()
        app.buttons["sources.selectAll"].tap()
        app.buttons["sources.batch.more"].tap()
        app.buttons["删除所选书源"].tap()
        XCTAssertTrue(app.alerts["删除 1 个书源？"].waitForExistence(timeout: 3))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.cells["sources.row.工具测试·故障"].exists)
        app.buttons["sources.batch.more"].tap()
        app.buttons["删除所选书源"].tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["没有匹配的书源"].waitForExistence(timeout: 3))
        app.navigationBars["书源"].buttons["完成"].tap()
        app.buttons["sources.filter"].tap()
        app.buttons["全部状态"].tap()
        let search = app.searchFields["搜索书源名称、网址或分组"]
        search.tap()
        search.typeText("空结果")
        XCTAssertTrue(app.cells["sources.row.工具测试·空结果"].exists)
        XCTAssertFalse(app.cells["sources.row.工具测试·正常"].exists)
    }

    @MainActor
    func testPasteImportRetainsReportAndInvalidInputIsNotSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset", "--uitesting-empty"]
        app.launch()
        app.tabBars.buttons["书源"].tap()
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["粘贴 JSON 导入"].tap()
        let editor = app.textViews["sources.pasteJSON"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("{\"bookSourceName\":\"粘贴测试\",\"bookSourceUrl\":\"https://paste.fixture.invalid\",\"enabled\":false}")
        app.navigationBars["粘贴书源 JSON"].buttons["导入"].tap()
        XCTAssertTrue(app.alerts["已导入 1 个书源"].waitForExistence(timeout: 10))
        app.alerts["已导入 1 个书源"].buttons["完成"].tap()
        XCTAssertTrue(app.cells["sources.row.粘贴测试"].exists)
        app.navigationBars["书源"].buttons["添加与管理书源"].tap()
        app.buttons["粘贴 JSON 导入"].tap()
        app.textViews["sources.pasteJSON"].tap()
        app.textViews["sources.pasteJSON"].typeText("not-json")
        app.navigationBars["粘贴书源 JSON"].buttons["导入"].tap()
        XCTAssertTrue(app.alerts["导入失败"].waitForExistence(timeout: 10))
    }
}
