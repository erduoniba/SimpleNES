//
//  SceneDelegate.swift
//  HDSimpleHappy
//
//  Created by denglibing5 on 2026/7/9.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?


  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    // App root is the player. The game library is a modal sheet the player VC presents on
    // demand — see ViewController.openLibrary().
    //
    // On cold launch we try to restore whatever the user was playing last time via
    // Prefs.lastPlayedHash → GameLibrary.entry(withHash:) → romURL → Data. Any missing link
    // (never played, ROM deleted from library, on-disk file moved out by another app) just
    // leaves the player in its no-ROM state; ViewController.viewDidAppear will then auto-open
    // the library sheet so the user has somewhere to go.
    guard let windowScene = (scene as? UIWindowScene) else { return }

    let player = ViewController()

    if let hash = Prefs.lastPlayedHash {
        let library = GameLibrary()
        if let entry = library.entry(withHash: hash),
           let data = try? Data(contentsOf: library.romURL(for: entry)) {
            player.preloadedROMData = data
            player.preloadedROMTitle = entry.displayName
        } else {
            // Pointer is stale (ROM was deleted or moved). Wipe it so we don't retry on every
            // launch; the auto-present will kick in and the user picks fresh.
            Prefs.clearLastPlayedHash()
        }
    }

    let nav = UINavigationController(rootViewController: player)
    let w = UIWindow(windowScene: windowScene)
    w.rootViewController = nav
    w.makeKeyAndVisible()
    self.window = w
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
  }

  func sceneWillResignActive(_ scene: UIScene) {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
  }


}

