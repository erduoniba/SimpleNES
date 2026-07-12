//
//  LibraryViewController.swift
//  HDSimpleNES
//
//  Modal sheet presented from the player VC. Lists imported ROMs; user taps a row to switch the
//  emulator to that ROM. Import happens here too (via UIDocumentPickerViewController), with the
//  same 覆盖/自定义名称 conflict flow as before.
//
//  Presentation model: this VC does NOT push anything itself. When the user picks a row we call
//  `onSelectROM` and expect the presenter to dismiss us + swap ROMs. Same for pure-import flows
//  — the user hits + to import, may dismiss us themselves after, or pick the imported entry to
//  start playing.
//
//  Import flow — the interesting part:
//    1. User picks a `.nes` from Files / iCloud via UIDocumentPickerViewController.
//    2. We read the bytes and hand them to `GameLibrary.preflight(...)` with a proposed display
//       name (the file's basename minus extension).
//    3. Three outcomes:
//         .free                            → commit silently, insert row at top
//         .sameContentAlreadyImported      → tell user "already in library" and stop
//         .nameConflict(existing)          → prompt "overwrite existing / rename / cancel"
//    4. On overwrite we drop the existing entry (and its ROM file + SRAM save — a different
//       game inheriting stale battery memory would be a fun bug), then commit the new bytes.
//       On rename we ask for a new name via a UIAlertController text field and re-preflight
//       (in case the user typed a name that ALSO collides).
//

import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UITableViewController {

    /// Fired when the user taps a row. Presenter is expected to dismiss us and load the ROM
    /// into its player. Bytes are read here (from the sandbox copy) so the presenter doesn't
    /// have to know about the on-disk layout.
    var onSelectROM: ((_ entry: GameEntry, _ data: Data) -> Void)?

    private let library = GameLibrary()
    /// Shared with the player VC — deleting a library entry ALSO deletes its .sram save file so
    /// a re-import of the same ROM later starts fresh.
    private let sramStore = SRAMStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "游戏列表"

        // Right: Import button — the only ROM entry point in the whole app.
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(importROM)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Import ROM"

        // Left: Close. We're presented as a modal sheet — swipe-down works too, but a visible
        // Close button is the standard escape hatch and reads clearly to users who don't know
        // the gesture.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        // Two-line cell (title + short hash subtitle) needs a bit more headroom than the default
        // 44pt — otherwise the subtitle clips into the separator. `automaticDimension` lets the
        // content configuration measure itself; `estimatedRowHeight` primes the scroll for smooth
        // insertion animation.
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        setupEmptyState()
    }

    @objc private func closeTapped() {
        // Presenter (the player VC) is our presentingViewController. Dismissing ourselves is
        // the modal-sheet convention — the player picks up wherever it left off.
        dismiss(animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Coming back from the emulator screen — nothing to re-fetch (the library is a live
        // model that mutates in-place), but the empty state visibility may have changed if the
        // user deleted the only entry from the swipe-action.
        tableView.reloadData()
        refreshEmptyState()
    }

    // MARK: - Empty state

    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = "还没导入 ROM\n点右上角 + 号选一个 .nes 文件"
        l.numberOfLines = 0
        l.textAlignment = .center
        l.textColor = .secondaryLabel
        l.font = .systemFont(ofSize: 15)
        return l
    }()

    private func setupEmptyState() {
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        refreshEmptyState()
    }

    private func refreshEmptyState() {
        emptyLabel.isHidden = !library.entries.isEmpty
    }

    // MARK: - Data source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return library.entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let entry = library.entries[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = entry.displayName
        // Short hash prefix as a subtle disambiguator between two different games that (were
        // renamed to have) similar labels. 8 hex chars = 32 bits, plenty for a personal library.
        config.secondaryText = String(entry.hash.prefix(8))
        config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        config.secondaryTextProperties.color = .tertiaryLabel
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    // MARK: - Selection → hand off to player

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = library.entries[indexPath.row]
        let url = library.romURL(for: entry)
        // Read the bytes here (not in the player) so any read failure surfaces at the list
        // level — the emulator VC never has to think about missing files. This is a rare
        // failure mode (user reached in via Files.app and moved the file out from under us) but
        // still worth a real error alert instead of a mystery reload.
        guard let data = try? Data(contentsOf: url) else {
            let alert = UIAlertController(
                title: "无法读取 ROM",
                message: "\(entry.displayName) 的文件不见了或已损坏，可能被其他 app 移动。请删除后重新导入。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }

        // Hand off to the player and dismiss ourselves. Player is on the presenter side —
        // dismissing runs the completion inline, meaning ROM swap happens under the sheet's
        // dismiss animation and by the time the player is visible again it's already playing
        // the new game.
        onSelectROM?(entry, data)
        dismiss(animated: true)
    }

    // MARK: - Swipe actions (delete + rename)

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = library.entries[indexPath.row]

        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            self?.confirmDelete(entry: entry, at: indexPath, completion: done)
        }
        let rename = UIContextualAction(style: .normal, title: "重命名") { [weak self] _, _, done in
            self?.promptRename(entry: entry, at: indexPath, completion: done)
        }
        rename.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [delete, rename])
    }

    private func confirmDelete(entry: GameEntry, at indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "删除《\(entry.displayName)》?",
            message: "ROM 与存档都会被删除，操作不可撤销。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { completion(false); return }
            // Delete the SRAM save file too — the alternative is that re-importing the same ROM
            // later silently resurrects a save from a game the user thought they wiped, which is
            // a nasty surprise for someone who deletes-to-restart.
            self.sramStore.deleteSaveFile(forHash: entry.hash)
            self.library.delete(hash: entry.hash)
            // If the deleted ROM was the last-played one, clear that pointer too — next cold
            // launch would otherwise try to load bytes that no longer exist on disk and fall
            // through to the empty state anyway, but explicit is better than the fallback.
            if Prefs.lastPlayedHash == entry.hash {
                Prefs.clearLastPlayedHash()
            }
            self.tableView.deleteRows(at: [indexPath], with: .automatic)
            self.refreshEmptyState()
            completion(true)
        })
        present(alert, animated: true)
    }

    private func promptRename(entry: GameEntry, at indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "重命名", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = entry.displayName
            tf.clearButtonMode = .whileEditing
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { completion(false); return }
            let newName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if newName.isEmpty || newName == entry.displayName {
                completion(false)
                return
            }
            if self.library.rename(hash: entry.hash, to: newName) {
                self.tableView.reloadRows(at: [indexPath], with: .automatic)
                completion(true)
            } else {
                // rename() only refuses when the new name is taken by a different entry.
                let e = UIAlertController(title: "名称已被占用", message: "已有一个游戏叫「\(newName)」。", preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .default))
                self.present(e, animated: true)
                completion(false)
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Import

    @objc private func importROM() {
        // .nes isn't a system-registered UTI, so we accept "any file" and rely on the emulator
        // core's iNES parser to reject non-ROMs at load time. asCopy:true means iOS hands us
        // the file in the app's temp dir — no security-scoped resource dance needed.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// The core of the import flow — takes freshly-picked bytes + a proposed name and drives the
    /// preflight/prompt/commit state machine. Recursive for the rename branch: if the user picks
    /// a new name that ALSO collides, we call ourselves with that new name.
    private func handleImport(data: Data, proposedName: String) {
        switch library.preflight(data: data, proposedName: proposedName) {
        case .free:
            commitImport(data: data, name: proposedName, overwriteHash: nil)

        case .sameContentAlreadyImported(let existing):
            let alert = UIAlertController(
                title: "已在列表中",
                message: "这个 ROM 已经作为「\(existing.displayName)」导入过了。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)

        case .nameConflict(let conflicting):
            presentConflictPrompt(data: data, proposedName: proposedName, conflicting: conflicting)
        }
    }

    /// The "覆盖 / 自定义名称 / 取消" prompt — the actual answer to the user's requirement.
    private func presentConflictPrompt(data: Data, proposedName: String, conflicting: GameEntry) {
        let alert = UIAlertController(
            title: "已有同名游戏",
            message: "列表里已经有一个叫「\(proposedName)」的游戏，但内容不同。你想怎么处理?",
            preferredStyle: .alert
        )
        // Overwrite: replace the existing entry's ROM bytes + display name is kept. The old
        // .sram is dropped too — it belonged to the *previous* ROM and would corrupt the new
        // game's battery memory on load.
        alert.addAction(UIAlertAction(title: "覆盖", style: .destructive) { [weak self] _ in
            self?.sramStore.deleteSaveFile(forHash: conflicting.hash)
            self?.commitImport(data: data, name: proposedName, overwriteHash: conflicting.hash)
        })
        // Custom name: ask for a new label, then re-run the whole preflight against that name.
        alert.addAction(UIAlertAction(title: "自定义名称", style: .default) { [weak self] _ in
            self?.promptCustomName(data: data, defaultName: proposedName)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func promptCustomName(data: Data, defaultName: String) {
        let alert = UIAlertController(title: "自定义名称", message: "为这次导入的游戏起个新名字。", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = defaultName
            tf.clearButtonMode = .whileEditing
            tf.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            let newName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !newName.isEmpty else { return }
            // Recurse — the new name might STILL collide (user typed another existing name), or
            // it might be free, or it might match a same-content-already-imported case. The
            // state machine handles all three uniformly.
            self?.handleImport(data: data, proposedName: newName)
        })
        present(alert, animated: true)
    }

    private func commitImport(data: Data, name: String, overwriteHash: String?) {
        guard let entry = library.commit(data: data, displayName: name, overwriteHash: overwriteHash) else {
            let alert = UIAlertController(title: "导入失败", message: "无法写入 ROM 文件到 App 沙盒。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        // New entry lives at the top (GameLibrary.commit inserts at index 0).
        tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
        refreshEmptyState()
        _ = entry
    }
}

// MARK: - UIDocumentPickerDelegate

extension LibraryViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let alert = UIAlertController(title: "读取失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return
        }
        // Basename without extension → default display name. `.nes` is stripped; other
        // extensions (some ROMs come as .zip or garbage) stay visible so the user notices.
        let name = url.deletingPathExtension().lastPathComponent
        handleImport(data: data, proposedName: name)
    }
}
