//
//  GameLibrary.swift
//  HDSimpleNES
//
//  Persistent index of imported ROMs. The user picks a `.nes` file once through the document
//  picker; we copy the bytes into `Documents/library/<sha256>.nes` and record an entry in
//  `Documents/library.json`. The list VC reads this store on load, and playback happens by
//  handing the on-disk ROM's bytes to EmulatorSession.
//
//  Duplicate handling is by DISPLAY NAME, not by hash:
//   - Same hash imported twice with the same name → silent dedup (same file, same label —
//     nothing meaningful for the user to decide).
//   - Same hash imported twice with a different name → still silent dedup; we keep whichever
//     entry the user already has, since the bytes are already on disk and the label they picked
//     first should stick.
//   - Different hash but same display name → we surface a conflict (overwrite / rename / cancel),
//     because that's the case a user can actually get wrong. Two distinct ROMs sharing a label
//     in the list would be confusing; asking is the right move.
//
//  The store is single-threaded — every method must be called from the main/UI thread. The list
//  VC is the only caller and it lives on the main thread, so this is a natural fit.
//

import CryptoKit
import Foundation

/// One row in the library list.
struct GameEntry: Codable, Equatable {
    /// Hex SHA-256 of the ROM's raw bytes. Doubles as the on-disk filename
    /// (`Documents/library/<hash>.nes`) and the SRAM-store key — same identity used everywhere.
    let hash: String
    /// What the user sees in the list. Defaults to the picked file's basename without extension;
    /// user can override at conflict-resolution time.
    var displayName: String
    /// Wall-clock time of first import. Kept for list sorting (newest first) and future "last
    /// played" style features. Encoded as ISO-8601 in library.json for human-readable diffs.
    let importedAt: Date
}

/// Outcome of a preflight check on a to-be-imported ROM. The caller (LibraryViewController) uses
/// this to decide whether to import silently or prompt the user.
enum ImportPreflight {
    /// Nothing on disk matches the hash and the display name is free — call `commit` directly.
    case free
    /// This exact ROM (same hash) is already in the library. `existing` is the entry that
    /// matched — the caller should just tell the user "already imported" and do nothing.
    case sameContentAlreadyImported(existing: GameEntry)
    /// The proposed display name is taken by a DIFFERENT ROM (different hash). Caller should
    /// prompt: overwrite `conflicting` with the new bytes, pick a new name, or cancel.
    case nameConflict(conflicting: GameEntry)
}

/// The store. Owns Documents/library.json and Documents/library/.
final class GameLibrary {

    /// All entries, sorted most-recently-imported first. Persisted to library.json on every
    /// mutation via `save()`. Public for the table view data source to read; mutations go
    /// through the API methods.
    private(set) var entries: [GameEntry] = []

    /// Directory holding the raw .nes files. One file per entry, named `<hash>.nes`.
    let romsDirectory: URL

    /// The on-disk JSON index. Sits next to `romsDirectory`, not inside it, so a rogue file
    /// scanner over the ROMs dir doesn't trip over it.
    private let indexURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.romsDirectory = docs.appendingPathComponent("library", isDirectory: true)
        self.indexURL = docs.appendingPathComponent("library.json")
        ensureDirectoryExists()
        load()
    }

    // MARK: - Query

    /// Absolute path to the copied ROM bytes for `entry`. May not exist if the file was deleted
    /// out from under us (e.g. user reached in via Files.app); caller should handle failure.
    func romURL(for entry: GameEntry) -> URL {
        return romsDirectory.appendingPathComponent("\(entry.hash).nes")
    }

    /// Look up an entry by hash. O(n) — the list is small (dozens of ROMs at most).
    func entry(withHash hash: String) -> GameEntry? {
        return entries.first { $0.hash == hash }
    }

    /// Look up an entry by display name (case-sensitive, exact match). Used for name-conflict
    /// detection at import time.
    func entry(withDisplayName name: String) -> GameEntry? {
        return entries.first { $0.displayName == name }
    }

    // MARK: - Import (preflight then commit)

    /// Inspect `data` and `proposedName` against the existing library. Doesn't mutate anything —
    /// the caller decides how to react to the outcome (silent import, silent skip, or prompt).
    func preflight(data: Data, proposedName: String) -> ImportPreflight {
        let hash = Self.sha256Hex(data)
        if let existing = entry(withHash: hash) {
            return .sameContentAlreadyImported(existing: existing)
        }
        if let conflicting = entry(withDisplayName: proposedName) {
            return .nameConflict(conflicting: conflicting)
        }
        return .free
    }

    /// Commit an import. Writes the ROM bytes to `Documents/library/<hash>.nes` and appends an
    /// entry to the index. If `overwriteHash` is non-nil, the existing entry with that hash is
    /// REPLACED — used by the "overwrite" branch of the conflict prompt to swap the display
    /// name's bytes without leaving orphaned files.
    ///
    /// Returns the newly inserted entry, or nil if the disk write failed.
    @discardableResult
    func commit(data: Data, displayName: String, overwriteHash: String? = nil) -> GameEntry? {
        let hash = Self.sha256Hex(data)

        // Handle the "overwrite" case first — the user picked "cover the existing entry called
        // '塞尔达传说' with these new bytes". We drop the old entry AND its files, THEN import
        // the new one. Overwriting a display name by swapping only the hash would leave two
        // entries sharing the label; drop-then-add avoids that whole class of state.
        if let overwriteHash = overwriteHash {
            delete(hash: overwriteHash)
        }

        let url = romsDirectory.appendingPathComponent("\(hash).nes")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[GameLibrary] failed to write ROM to \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        let entry = GameEntry(hash: hash, displayName: displayName, importedAt: Date())
        // Newest first — matches the sort we hand back to the table view.
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    /// Rename an existing entry. No-op if no entry with that hash exists, or the new name is
    /// already taken by a different entry (caller should preflight before calling — this is a
    /// belt-and-suspenders check so the on-disk state never has two entries sharing a name).
    @discardableResult
    func rename(hash: String, to newName: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.hash == hash }) else { return false }
        if let taken = entry(withDisplayName: newName), taken.hash != hash { return false }
        entries[idx].displayName = newName
        save()
        return true
    }

    /// Remove an entry from the index and delete its ROM file. Idempotent — calling on a
    /// missing hash is a no-op. The associated `.sram` save file is NOT touched here; the
    /// caller is expected to handle SRAM cleanup separately (see LibraryViewController).
    func delete(hash: String) {
        guard let idx = entries.firstIndex(where: { $0.hash == hash }) else { return }
        entries.remove(at: idx)
        let url = romsDirectory.appendingPathComponent("\(hash).nes")
        // Best-effort — a missing file is fine (nothing to delete), any other error we swallow
        // and log. The user's mental model is "delete from list" and we've done that; leaving
        // a stray file on disk is annoying but not incorrect.
        do {
            try FileManager.default.removeItem(at: url)
        } catch let err as NSError where err.domain == NSCocoaErrorDomain && err.code == NSFileNoSuchFileError {
            // No file, no problem.
        } catch {
            NSLog("[GameLibrary] failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
        save()
    }

    // MARK: - Persistence

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: romsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Read the index. Missing file → empty library (fresh install). Malformed JSON → we log
    /// and start empty rather than crash; the alternative is that one hand-edit to the JSON
    /// bricks the app for a user who has no way to recover.
    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([GameEntry].self, from: data)
        } catch {
            NSLog("[GameLibrary] failed to parse library.json (\(error.localizedDescription)) — starting empty")
            entries = []
        }
    }

    /// Serialize + atomically overwrite `library.json`. Called after every mutation. Small file
    /// (< 4 KB for any realistic library size), sync write is fine.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("[GameLibrary] failed to save library.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Hashing

    /// Hex-encoded lowercase SHA-256. Same routine as SRAMStore so an entry's `hash` string is
    /// interchangeable with the SRAM key — same identity everywhere.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
