import XCTest
@testable import Yuedu

final class ReaderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testReadingPreferencesSurviveReload() {
        let preferences = ReaderPreferences(fontSize: 26, lineSpacing: 17, paper: .night)
        preferences.save(defaults: defaults)
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 26)
        XCTAssertEqual(restored.lineSpacing, 17)
        XCTAssertEqual(restored.paper, .night)
    }

    func testOutOfRangeSettingsRemainReadable() {
        defaults.set(300, forKey: "reader.fontSize")
        defaults.set(-50, forKey: "reader.lineSpacing")
        defaults.set("unavailable-theme", forKey: "reader.paper")
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 30)
        XCTAssertEqual(restored.lineSpacing, 4)
        XCTAssertEqual(restored.paper, .ivory)
    }

    func testInvalidStoredTypesUseReadableDefaults() {
        defaults.set("invalid-number", forKey: "reader.fontSize")
        defaults.set(["invalid"], forKey: "reader.lineSpacing")
        let restored = ReaderPreferences.load(defaults: defaults)
        XCTAssertEqual(restored.fontSize, 21)
        XCTAssertEqual(restored.lineSpacing, 11)
    }
}
