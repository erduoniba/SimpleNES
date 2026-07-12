//
//  SettingsViewController.swift
//  HDSimpleHappy
//
//  Modal sheet presented from the player VC's gear button. Currently exposes one setting group —
//  gamepad theme — with each `GamepadTheme.all` entry rendered as a checkmark-selectable row.
//
//  Structured as a UITableViewController with a single section so adding future settings (sound
//  toggle, controller mapping, haptics, ...) is one more section append rather than a rewrite.
//  The theme picker used to be an action sheet on the nav bar; moving it here keeps the gameplay
//  nav bar clean (one gear button) and gives room for the settings surface to grow.
//
//  Persistence + live apply are decoupled: rows write to `Prefs.setSelectedTheme` immediately
//  (so a mid-selection crash preserves the choice) and also fire `onThemeChanged` so the
//  presenter can update the on-screen gamepad without waiting for the sheet to dismiss.
//

import UIKit

final class SettingsViewController: UITableViewController {

    /// Fired every time the user taps a theme row. Presenter is expected to call its own
    /// `applyTheme(_:)` so the gamepad restyles immediately under the sheet — the sheet stays
    /// open so the user can preview several themes without dismiss/re-open churn.
    var onThemeChanged: ((GamepadTheme) -> Void)?

    /// Locally tracked selection so the checkmark can move without reloading `Prefs` on every
    /// cellForRow call. Initialized from Prefs; kept in sync when the user picks a new row.
    private var selectedThemeID: GamepadTheme.ID = Prefs.selectedTheme ?? GamepadTheme.all[0].id

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "按键样式"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return GamepadTheme.all.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let theme = GamepadTheme.all[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = theme.displayName
        cell.contentConfiguration = config
        // Checkmark moves as the user taps; the presenter re-skins the gamepad live under the
        // sheet so this is genuine preview, not just a stored preference.
        cell.accessoryType = (theme.id == selectedThemeID) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let theme = GamepadTheme.all[indexPath.row]
        guard theme.id != selectedThemeID else { return }

        // Recompute which rows need the checkmark redrawn — just the two: the previous selection
        // (clear it) and the new one (set it). Reloading the whole section works too but flickers.
        let previousID = selectedThemeID
        selectedThemeID = theme.id

        var toReload: [IndexPath] = [indexPath]
        if let prevRow = GamepadTheme.all.firstIndex(where: { $0.id == previousID }) {
            toReload.append(IndexPath(row: prevRow, section: indexPath.section))
        }
        tableView.reloadRows(at: toReload, with: .none)

        // Fire the callback — presenter both persists (via its own `applyTheme` → `Prefs.set…`)
        // and restyles the on-screen gamepad. We don't call Prefs directly here to keep the
        // single source of truth on the presenter side.
        onThemeChanged?(theme)
    }
}
