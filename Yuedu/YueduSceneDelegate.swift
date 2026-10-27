import UIKit

final class YueduSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var appearanceObserver: NSObjectProtocol?
    private var pendingDocumentURL: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = Theme.accent
        window.overrideUserInterfaceStyle = ReaderPreferences.load().paper == .night ? .dark : .unspecified
        window.rootViewController = MainTabBarController()
        self.window = window

        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .yueduAppearanceChanged, object: nil, queue: .main
        ) { [weak window] _ in
            window?.overrideUserInterfaceStyle = ReaderPreferences.load().paper == .night ? .dark : .unspecified
        }

        // Cold-launch file URLs arrive here, rather than in openURLContexts.
        // Wait until the scene is active before presenting the imported book.
        pendingDocumentURL = connectionOptions.urlContexts.first?.url
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        importPendingDocument()
        if UserDefaults.standard.bool(forKey: "following.autoCheck") {
            YueduFollowingManager.shared.start(automatic: true)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        YueduFollowingManager.shared.cancel()
        YueduSourceChecker.shared.cancel()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        pendingDocumentURL = url
        if scene.activationState == .foregroundActive {
            importPendingDocument()
        }
    }

    private func importPendingDocument() {
        guard let url = pendingDocumentURL,
              let tabs = window?.rootViewController as? MainTabBarController else { return }
        pendingDocumentURL = nil

        let openDocument = {
            tabs.selectedIndex = 0
            (tabs.selectedViewController as? UINavigationController)?.popToRootViewController(animated: false)
            tabs.bookshelf.importDocument(url)
        }
        if tabs.presentedViewController != nil {
            tabs.dismiss(animated: false, completion: openDocument)
        } else {
            openDocument()
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }
}
