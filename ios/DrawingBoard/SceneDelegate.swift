import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = BoardViewController.boardColor
        window.rootViewController = BoardViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneWillResignActive(_ scene: UIScene) {
        board?.snapshotStorage()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        board?.snapshotStorage()
    }

    private var board: BoardViewController? {
        window?.rootViewController as? BoardViewController
    }
}
