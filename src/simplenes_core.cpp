// Thin C-ABI wrapper around sn::CoreEmulator. Every function here just forwards to a method on
// the inner C++ object. Kept intentionally boring — no logic lives here.

#include "simplenes_core.h"

#include "APU/Constants.h"
#include "APU/spsc.hpp"
#include "Controller.h"
#include "CoreEmulator.h"
#include "LastError.h"
#include "VirtualScreen.h"

struct sn_emulator
{
    sn::CoreEmulator inner;
};

extern "C" int sn_frame_width(void)
{
    return sn::ScanlineVisibleDots;
}

extern "C" int sn_frame_height(void)
{
    return sn::VisibleScanlines;
}

extern "C" sn_emulator* sn_emulator_create(void)
{
    // If allocation throws (unlikely in practice), swallow it and return NULL so the C ABI stays
    // exception-free.
    try
    {
        return new sn_emulator{};
    }
    catch (...)
    {
        return nullptr;
    }
}

extern "C" void sn_emulator_destroy(sn_emulator* emu)
{
    delete emu;
}

extern "C" int sn_emulator_load_rom_file(sn_emulator* emu, const char* path)
{
    if (!emu || !path)
        return -1;
    return emu->inner.loadROMFile(path) ? 0 : -1;
}

extern "C" int sn_emulator_load_rom_memory(sn_emulator* emu, const uint8_t* data, size_t len)
{
    if (!emu || !data)
        return -1;
    return emu->inner.loadROMMemory(data, len) ? 0 : -1;
}

extern "C" int sn_emulator_reset(sn_emulator* emu)
{
    if (!emu)
        return -1;
    return emu->inner.reset() ? 0 : -1;
}

extern "C" void sn_emulator_step_frame(sn_emulator* emu)
{
    if (emu)
        emu->inner.stepFrame();
}

extern "C" void sn_emulator_step_cycle(sn_emulator* emu)
{
    if (emu)
        emu->inner.stepCycle();
}

extern "C" const uint32_t* sn_emulator_framebuffer(sn_emulator* emu)
{
    if (!emu)
        return nullptr;
    return emu->inner.screen().pixels();
}

extern "C" void sn_emulator_set_button(sn_emulator* emu, int controller_idx, int button, int pressed)
{
    if (!emu)
        return;
    if (controller_idx < 0 || controller_idx > 1)
        return;
    if (button < 0 || button >= sn::Controller::TotalButtons)
        return;
    emu->inner.controller(controller_idx)
      .setButtonState(static_cast<sn::Controller::Buttons>(button), pressed != 0);
}

extern "C" size_t sn_emulator_pull_audio(sn_emulator* emu, float* out, size_t max_samples)
{
    if (!emu || !out || max_samples == 0)
        return 0;
    return emu->inner.audioQueue().pop(out, max_samples);
}

extern "C" int sn_emulator_audio_input_rate(void)
{
    // Matches CoreEmulator's internal apu_input_sample_rate() computation — kept in sync manually.
    return static_cast<int>(1.0 / sn::apu_clock_period_s.count());
}

extern "C" int sn_emulator_audio_output_rate(void)
{
    return sn::CoreEmulator::kDefaultAudioOutputSampleRate;
}

extern "C" const char* sn_last_error(void)
{
    return sn::getLastErrorCStr();
}

extern "C" size_t sn_emulator_sram_size(sn_emulator* emu)
{
    if (!emu) return 0;
    return emu->inner.sramSize();
}

extern "C" const uint8_t* sn_emulator_sram_data(sn_emulator* emu)
{
    if (!emu) return nullptr;
    return emu->inner.sramData();
}

extern "C" size_t sn_emulator_set_sram_data(sn_emulator* emu, const uint8_t* data, size_t len)
{
    if (!emu || !data || len == 0) return 0;
    return emu->inner.setSRAMData(data, len);
}
