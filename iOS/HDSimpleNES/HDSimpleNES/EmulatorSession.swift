//
//  EmulatorSession.swift
//  HDSimpleHappy
//
//  Thin Swift wrapper around the SimpleNESCore C API. Owns the sn_emulator* handle for the
//  lifetime of the instance, exposes idiomatic Swift methods, and enforces that only one Swift
//  object at a time speaks to the underlying C object.
//

import Foundation

/// Buttons on a standard NES controller. Raw values MUST stay in sync with SN_BUTTON_* in
/// simplenes_core.h — the C API uses the integer directly.
enum NESButton: Int32 {
    case a      = 0
    case b      = 1
    case select = 2
    case start  = 3
    case up     = 4
    case down   = 5
    case left   = 6
    case right  = 7
}

final class EmulatorSession {

    let frameWidth: Int
    let frameHeight: Int
    /// APU-tick sample rate (~894454 Hz). Samples come out of the queue at this rate.
    let audioInputRate: Int
    /// The rate the core targets internally — currently 44100 Hz. Not what the audio callback
    /// necessarily runs at; the callback picks whatever the hardware wants and NESAudioEngine
    /// resamples on the fly.
    let audioOutputRate: Int

    private(set) var hasROM = false

    private var handle: OpaquePointer

    init?() {
        guard let h = sn_emulator_create() else { return nil }
        self.handle = h
        self.frameWidth = Int(sn_frame_width())
        self.frameHeight = Int(sn_frame_height())
        self.audioInputRate = Int(sn_emulator_audio_input_rate())
        self.audioOutputRate = Int(sn_emulator_audio_output_rate())
    }

    deinit {
        sn_emulator_destroy(handle)
    }

    // MARK: - ROM

    /// Load a ROM from a filesystem path. Automatically resets the emulator on success.
    @discardableResult
    func loadROM(path: String) -> Bool {
        let loaded = sn_emulator_load_rom_file(handle, path) == 0
        guard loaded else { hasROM = false; return false }
        let reset = sn_emulator_reset(handle) == 0
        hasROM = reset
        return reset
    }

    /// Load a ROM already resident in memory (e.g. from Data returned by a document picker).
    /// Automatically resets on success.
    @discardableResult
    func loadROM(data: Data) -> Bool {
        let loaded: Bool = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return sn_emulator_load_rom_memory(handle, base, raw.count) == 0
        }
        guard loaded else { hasROM = false; return false }
        let reset = sn_emulator_reset(handle) == 0
        hasROM = reset
        return reset
    }

    // MARK: - Stepping

    /// Advance one full NES frame (~29781 CPU cycles). No-op if no ROM is loaded.
    func stepFrame() {
        guard hasROM else { return }
        sn_emulator_step_frame(handle)
    }

    /// Soft-reset the currently loaded ROM (equivalent to pressing the physical NES Reset button).
    /// Re-runs CPU/PPU reset vectors but keeps the mapper's PRG/CHR state — same behavior a real
    /// NES has when you hit Reset without popping the cartridge. No-op with no ROM loaded.
    @discardableResult
    func reset() -> Bool {
        guard hasROM else { return false }
        return sn_emulator_reset(handle) == 0
    }

    // MARK: - Video

    /// Pointer to the 256×240 RGBA8 framebuffer. Valid until the next call that mutates emulator
    /// state (any step_* call). Bytes are in [R,G,B,A] order — matches Metal's rgba8Unorm.
    var framebufferPointer: UnsafePointer<UInt32>? {
        return sn_emulator_framebuffer(handle)
    }

    // MARK: - Input

    /// controller: 0 = P1, 1 = P2.
    func setButton(_ button: NESButton, pressed: Bool, controller: Int = 0) {
        sn_emulator_set_button(handle, Int32(controller), button.rawValue, pressed ? 1 : 0)
    }

    // MARK: - Audio

    /// Pull up to `maxSamples` mono float samples out of the emulator's ring buffer. Safe to call
    /// from the audio thread as long as it is the SOLE reader (SPSC semantics).
    @discardableResult
    func pullAudio(into buffer: UnsafeMutablePointer<Float>, maxSamples: Int) -> Int {
        return sn_emulator_pull_audio(handle, buffer, maxSamples)
    }

    // MARK: - Diagnostics

    /// Human-readable message from the last failed core call on this thread. Empty when the last
    /// call succeeded. Read this immediately after a `loadROM(...)` that returned false to show a
    /// specific reason (unsupported mapper #241, PAL ROM, truncated buffer, ...).
    var lastError: String {
        guard let c = sn_last_error() else { return "" }
        return String(cString: c)
    }

    // MARK: - Battery-backed SRAM

    /// Size in bytes of the battery-backed cartridge RAM the current ROM exposes. 0 for ROMs
    /// without persistent memory — the emulator's iNES parser only reports non-zero here when
    /// header byte-6 bit-1 is set, or when the mapper itself owns PRG-RAM (MMC3 → 32 KB).
    var sramSize: Int {
        return sn_emulator_sram_size(handle)
    }

    /// Snapshot the current SRAM as a `Data` copy. Nil when `sramSize == 0`. Copies rather than
    /// exposing the raw pointer because the pointer's lifetime is tied to the mapper (invalid
    /// after the next `loadROM` / `reset`) and hosts want to hand this off to `Data.write`.
    var sramData: Data? {
        let size = sramSize
        guard size > 0, let p = sn_emulator_sram_data(handle) else { return nil }
        return Data(bytes: p, count: size)
    }

    /// Overwrite the live SRAM buffer with `data`, up to `sramSize` bytes. Returns the number
    /// of bytes actually written (clamped by the buffer size). Call this immediately after
    /// `loadROM(...)` to restore a persisted save — the mapper is only alive post-reset, and
    /// stepping starts on the next `stepFrame()` call.
    @discardableResult
    func setSRAMData(_ data: Data) -> Int {
        guard sramSize > 0 else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return sn_emulator_set_sram_data(handle, base, raw.count)
        }
    }
}
