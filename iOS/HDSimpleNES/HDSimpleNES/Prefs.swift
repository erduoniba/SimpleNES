//
//  Prefs.swift
//  HDSimpleHappy
//
//  A single place for the app's small persistent settings. Currently one key: the SHA-256 hash
//  of the ROM the user was playing when they last closed the app. SceneDelegate reads this on
//  cold launch to auto-load whatever the user was doing, so the "you were playing 塞尔达传说"
//  state survives across kills.
//
//  Kept as a namespace of static functions rather than an instance-with-DI because there's
//  exactly one UserDefaults.standard and nothing to inject — this reads more like a `.strings`
//  file than a service.
//

import Foundation

enum Prefs {

    /// UserDefaults key. Bare hex string of the SHA-256 of the ROM's raw bytes, or nil/absent
    /// if the user has never played anything (or the last ROM was deleted from the library).
    private static let lastPlayedHashKey = "lastPlayedHash"

    /// UserDefaults key. Raw value of `GamepadTheme.ID` (a stable kebab-case string). Absent on
    /// first launch and after any downgrade that removed a theme the user had picked.
    private static let selectedThemeKey = "selectedThemeID"

    /// The SHA-256 hex of the most recently played ROM, or nil if there isn't one.
    static var lastPlayedHash: String? {
        return UserDefaults.standard.string(forKey: lastPlayedHashKey)
    }

    /// Record which ROM the user is playing now. Called every time a ROM is loaded (both from
    /// cold-launch preload and from the library-sheet selection path) — if the app is killed
    /// mid-game we want the freshest hash on disk.
    static func setLastPlayedHash(_ hash: String) {
        UserDefaults.standard.set(hash, forKey: lastPlayedHashKey)
    }

    /// Clear the record. Used when the ROM behind the last-played hash is deleted from the
    /// library — we don't want the next launch trying to load bytes that aren't there anymore.
    static func clearLastPlayedHash() {
        UserDefaults.standard.removeObject(forKey: lastPlayedHashKey)
    }

    // MARK: - Theme

    /// The user's chosen gamepad/background theme. Nil-when-absent case is the first launch
    /// (before the user ever opened the theme picker) — callers should fall back to the first
    /// entry in `GamepadTheme.all` (currently `.classicGray`).
    static var selectedTheme: GamepadTheme.ID? {
        guard let raw = UserDefaults.standard.string(forKey: selectedThemeKey) else { return nil }
        return GamepadTheme.ID(rawValue: raw)
    }

    /// Record the user's theme pick. Called from the picker sheet in ViewController. Persists
    /// immediately so a crash right after selecting doesn't lose the choice.
    static func setSelectedTheme(_ id: GamepadTheme.ID) {
        UserDefaults.standard.set(id.rawValue, forKey: selectedThemeKey)
    }
}
