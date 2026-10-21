import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yuedu")
            try? FileManager.default.removeItem(at: directory)
            for key in ["reader.fontSize", "reader.lineSpacing", "reader.paper", "reader.turnStyle", "reader.fullScreen", "reader.fullScreenStatusBar", "reader.typography", "shelf.sort", "shelf.showSamples", "following.autoCheck", "search.history"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset"),
           !ProcessInfo.processInfo.arguments.contains("--uitesting-empty") {
            for book in SampleLibrary.books { LibraryStore.shared.add(book) }
            UserDefaults.standard.set(true, forKey: "shelf.showSamples")
        }
        #endif
        _ = YueduDownloadManager.shared
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.tintColor = Theme.accent
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = MainTabBarController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == YueduBackgroundTransfer.identifier else {
            completionHandler()
            return
        }
        YueduBackgroundTransfer.shared.handleEvents(completion: completionHandler)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if UserDefaults.standard.bool(forKey: "following.autoCheck") {
            YueduFollowingManager.shared.start(automatic: true)
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        YueduFollowingManager.shared.cancel()
        YueduSourceChecker.shared.cancel()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let tabs = window?.rootViewController as? MainTabBarController else { return false }
        tabs.selectedIndex = 0
        (tabs.selectedViewController as? UINavigationController)?.popToRootViewController(animated: false)
        tabs.bookshelf.importDocument(url)
        return true
    }
}

final class MainTabBarController: UITabBarController {
    let bookshelf = BookshelfViewController()
    override var childForStatusBarStyle: UIViewController? { selectedViewController }
    override var childForStatusBarHidden: UIViewController? { selectedViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { selectedViewController }
    override func viewDidLoad() {
        super.viewDidLoad()
        let screens: [(UIViewController, String, String, String)] = [
            (bookshelf, "书架", "books.vertical", "books.vertical.fill"),
            (DiscoverViewController(), "发现", "safari", "safari.fill"),
            (SourcesViewController(), "书源", "square.stack.3d.up", "square.stack.3d.up.fill"),
            (ProfileViewController(), "我的", "person.crop.circle", "person.crop.circle.fill")
        ]
        viewControllers = screens.map { screen, title, icon, selected in
            let nav = ReadingNavigationController(rootViewController: screen)
            nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), selectedImage: UIImage(systemName: selected))
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = Theme.bg
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = [.foregroundColor: Theme.ink]
            nav.navigationBar.standardAppearance = appearance
            nav.navigationBar.scrollEdgeAppearance = appearance
            nav.navigationBar.tintColor = Theme.accent
            return nav
        }
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.bg
        appearance.shadowColor = Theme.line
        appearance.stackedLayoutAppearance.selected.iconColor = Theme.accent
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: Theme.accent]
        appearance.stackedLayoutAppearance.normal.iconColor = Theme.secondary
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = Theme.accent
    }
}

final class ReadingNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
}
