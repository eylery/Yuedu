import XCTest
import UIKit
@testable import Yuedu

@MainActor
final class YueduSceneLifecycleTests: XCTestCase {
    private func applicationScene() async throws -> UIWindowScene {
        for _ in 0..<100 {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { ($0.delegate as? YueduSceneDelegate)?.window != nil }) {
                return scene
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try XCTUnwrap(nil as UIWindowScene?, "UIKit did not connect the application's scene delegate.")
    }

    func testSystemConnectsSceneDelegateAndMainWindow() async throws {
        let scene = try await applicationScene()
        let delegate = try XCTUnwrap(scene.delegate as? YueduSceneDelegate)
        let window = try XCTUnwrap(delegate.window)
        XCTAssertTrue(window.windowScene === scene)
        XCTAssertTrue(scene.windows.contains(where: { $0 === window }))
        XCTAssertFalse(window.isHidden)
        let tabs = try XCTUnwrap(window.rootViewController as? MainTabBarController)
        XCTAssertEqual(tabs.viewControllers?.count, 4)
        XCTAssertFalse(UIApplication.shared.supportsMultipleScenes)
    }

    func testSceneWindowRespondsToAppearanceChanges() async throws {
        let scene = try await applicationScene()
        let window = try XCTUnwrap((scene.delegate as? YueduSceneDelegate)?.window)
        let originalPaper = UserDefaults.standard.object(forKey: "reader.paper")
        defer {
            UserDefaults.standard.set(originalPaper, forKey: "reader.paper")
            NotificationCenter.default.post(name: .yueduAppearanceChanged, object: nil)
        }

        for (paper, style) in [("night", UIUserInterfaceStyle.dark), ("ivory", .unspecified)] {
            UserDefaults.standard.set(paper, forKey: "reader.paper")
            NotificationCenter.default.post(name: .yueduAppearanceChanged, object: nil)
            XCTAssertEqual(window.overrideUserInterfaceStyle, style)
        }
    }
}
