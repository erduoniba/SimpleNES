#ifndef SIMPLENES_CORE_H
#define SIMPLENES_CORE_H

#include <stddef.h>
#include <stdint.h>

// C ABI boundary for SimpleNESCore. Hosts written in a language that speaks C (Objective-C,
// Objective-C++, Swift via bridging, Kotlin/JNI, etc.) can drive the emulator through this
// header without knowing anything about the internal C++ classes.
//
// The desktop SFML host does NOT go through this API — it uses sn::CoreEmulator directly in C++
// for zero-overhead. This header exists specifically so an iOS host (or any non-C++ frontend)
// can consume the same libSimpleNESCore.a static library.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sn_emulator sn_emulator;

// Frame dimensions — fixed constants exposed as functions so callers don't need to hard-code them
// or match a specific #define.
int sn_frame_width(void);   // 256
int sn_frame_height(void);  // 240

// Button indices matching sn::Controller::Buttons. Kept in sync manually.
enum {
    SN_BUTTON_A      = 0,
    SN_BUTTON_B      = 1,
    SN_BUTTON_SELECT = 2,
    SN_BUTTON_START  = 3,
    SN_BUTTON_UP     = 4,
    SN_BUTTON_DOWN   = 5,
    SN_BUTTON_LEFT   = 6,
    SN_BUTTON_RIGHT  = 7
};

// Lifecycle. sn_emulator_create returns NULL on allocation failure.
sn_emulator* sn_emulator_create(void);
void         sn_emulator_destroy(sn_emulator* emu);

// ROM loading — 0 on success, non-zero on failure. Must be followed by sn_emulator_reset()
// before the first step. On failure, sn_last_error() returns a human-readable one-liner
// describing why (unsupported mapper, PAL ROM, truncated buffer, etc.).
int sn_emulator_load_rom_file(sn_emulator* emu, const char* path);
int sn_emulator_load_rom_memory(sn_emulator* emu, const uint8_t* data, size_t len);

// Prepare CPU + PPU + mapper for execution after a successful load. 0 on success.
int sn_emulator_reset(sn_emulator* emu);

// Last error message from any core call in the current thread. Never NULL — returns an empty
// string when nothing has failed yet. Valid until the next core call on this thread.
const char* sn_last_error(void);

// Advance one full NES frame (~29781 CPU cycles).
void sn_emulator_step_frame(sn_emulator* emu);

// Advance one CPU cycle (which drives 3 PPU cycles + 1 APU cycle). Sub-frame granularity for
// hosts that want an elapsed-time-driven loop.
void sn_emulator_step_cycle(sn_emulator* emu);

// Framebuffer: 256x240 pixels, one uint32_t per pixel in memory as bytes [R,G,B,A]. Pointer is
// valid until the next call to any step function or until the emulator is destroyed.
const uint32_t* sn_emulator_framebuffer(sn_emulator* emu);

// Input. controller_idx: 0=P1, 1=P2. button: one of SN_BUTTON_*. pressed: non-zero for down.
void sn_emulator_set_button(sn_emulator* emu, int controller_idx, int button, int pressed);

// Audio. The core writes mono float samples into an internal SPSC ring buffer at approximately
// sn_emulator_audio_input_rate() Hz. The host pulls them via sn_emulator_pull_audio(). Returns
// the number of samples actually written to `out` (may be less than `max_samples` if the queue
// is empty).
size_t sn_emulator_pull_audio(sn_emulator* emu, float* out, size_t max_samples);

// Sample rate at which the core produces samples (before any host-side resampling). This is the
// APU tick rate, approximately 894886 Hz on NTSC.
int sn_emulator_audio_input_rate(void);

// Output sample rate the core targets internally (currently 44100). Fixed at compile time.
int sn_emulator_audio_output_rate(void);

#ifdef __cplusplus
}
#endif

#endif // SIMPLENES_CORE_H
