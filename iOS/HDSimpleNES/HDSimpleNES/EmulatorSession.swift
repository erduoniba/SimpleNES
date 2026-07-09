//
//  EmulatorSession.swift
//  HDSimpleNES
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
}
