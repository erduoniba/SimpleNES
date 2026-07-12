//
//  SRAMStore.swift
//  HDSimpleHappy
//
//  Battery-backed cartridge RAM persistence. On real hardware the cartridge has a coin battery
//  that keeps $6000-$7FFF alive across power cycles — that's how Zelda passwords, Final Fantasy
//  parties, MMC3-era JRPG progress survive. On iOS we mirror that by snapshotting the emulator's
//  live SRAM buffer to a file whenever the game window closes (foreground → background, user
//  hits Reset, VC deinits, app terminates) and restoring it when the same ROM is loaded again.
//
//  Save identity is keyed by SHA-256 of the raw ROM bytes rather than filename, so:
//   - Renaming the ROM file doesn't lose the save.
//   - Two ROMs with the same iNES header but different PRG contents (e.g. a translation patch)
//     get distinct save files.
//   - Two copies of the same ROM in different folders share the save (usually what the user
//     wants — the alternative is "why did opening the same game from a different folder lose
//     my progress").
//
//  Files live in Documents/saves/<hex-sha256>.sram. Documents is backed up by iCloud/iTunes,
//  which is the right home for save files (Application Support would be caches-adjacent, tmp/
//  gets pruned). We do NOT compress or checksum — SRAM is 8 KB to 32 KB, tiny, and readable in
//  a hex editor is a feature (users occasionally hand-edit these).
//

import CryptoKit
import Foundation

/// Persists battery-backed cartridge RAM to disk, keyed by the ROM's content hash.
///
/// Not thread-safe — every method must be called from the same thread (the UI thread in this
/// app). The emulator core is single-threaded on the UI thread too, so this is a natural fit.
final class SRAMStore {

    /// Absolute path to the directory holding all .sram files. Created on first access.
    let savesDirectory: URL

    /// Hex-encoded SHA-256 of the currently loaded ROM's raw bytes. `nil` before any ROM
    /// has been loaded through this store — clearRomHash() also resets it.
    private(set) var currentROMHash: String?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.savesDirectory = docs.appendingPathComponent("saves", isDirectory: true)
        ensureDirectoryExists()
    }

    // MARK: - Public API

    /// Compute and remember the ROM hash for the ROM the emulator is about to load. Call this
    /// BEFORE `session.loadROM(data:)` so `loadSaveIntoSession(_:)` immediately after knows
    /// which file to restore from. Returns the hex-encoded hash (also stored in
    /// `currentROMHash`) so the caller can log it.
    @discardableResult
    func rememberROM(data: Data) -> String {
        let hash = Self.sha256Hex(data)
        currentROMHash = hash
        return hash
    }

    /// Forget which ROM is loaded — call this if `session.loadROM` failed, so a subsequent
    /// save-on-background doesn't overwrite the *previous* ROM's save file with the failed
    /// ROM's SRAM garbage.
    func clearRomHash() {
        currentROMHash = nil
    }

    /// Delete the on-disk `.sram` file for a given ROM hash. Used by the library when the user
    /// removes a ROM (or picks "覆盖" during an import conflict) — a stale battery-save from a
    /// different game inheriting the same display-name would corrupt the new game's memory.
    /// Idempotent: missing file is a no-op.
    func deleteSaveFile(forHash hash: String) {
        let url = savesDirectory.appendingPathComponent("\(hash).sram")
        do {
            try FileManager.default.removeItem(at: url)
            NSLog("[SRAMStore] removed \(url.lastPathComponent)")
        } catch let err as NSError where err.domain == NSCocoaErrorDomain && err.code == NSFileNoSuchFileError {
            // No save yet — nothing to delete.
        } catch {
            NSLog("[SRAMStore] delete failed: \(error.localizedDescription)")
        }
    }

    /// Restore any persisted save into the emulator's live SRAM buffer, if the currently
    /// remembered ROM has one on disk AND the emulator reports non-zero `sramSize`. Must be
    /// called AFTER a successful `session.loadROM(...)` (which internally calls reset(), and
    /// the mapper is only alive post-reset).
    ///
    /// Returns the number of bytes actually restored (0 if there was no save file, the ROM
    /// isn't battery-backed, or the file was truncated/oversized — we still write in as much
    /// as fits either way).
    @discardableResult
    func loadSaveIntoSession(_ session: EmulatorSession) -> Int {
        guard let hash = currentROMHash else { return 0 }
        let size = session.sramSize
        guard size > 0 else { return 0 }
        let url = savesDirectory.appendingPathComponent("\(hash).sram")
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let written = session.setSRAMData(data)
        NSLog("[SRAMStore] restored \(written) bytes from \(url.lastPathComponent) (file: \(data.count), buffer: \(size))")
        return written
    }

    /// Snapshot the emulator's current SRAM to disk under the remembered ROM's hash. Idempotent
    /// (safe to call on every background transition). No-op if the ROM isn't battery-backed
    /// (sramSize == 0) or no ROM has been remembered.
    ///
    /// Uses atomic write: `Data.write(to:, options: .atomic)` writes to a temp file and renames,
    /// so a crash mid-write can't corrupt the previous save.
    @discardableResult
    func saveFromSession(_ session: EmulatorSession) -> Bool {
        guard let hash = currentROMHash else { return false }
        guard let data = session.sramData else { return false }
        if data.isEmpty { return false }
        let url = savesDirectory.appendingPathComponent("\(hash).sram")
        do {
            try data.write(to: url, options: .atomic)
            NSLog("[SRAMStore] saved \(data.count) bytes to \(url.lastPathComponent)")
            return true
        } catch {
            NSLog("[SRAMStore] save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Internals

    private func ensureDirectoryExists() {
        // Documents/saves may not exist yet on a fresh install. FileManager.createDirectory is
        // a no-op if it does — the withIntermediateDirectories flag makes that guarantee.
        try? FileManager.default.createDirectory(
            at: savesDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Hex-encoded SHA-256 of `data`, lowercase. CryptoKit's `SHA256.hash` yields a
    /// `SHA256.Digest` whose `description` is not stable — build the hex string ourselves so
    /// the file names are portable and diffable.
    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
