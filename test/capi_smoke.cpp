// Handwritten smoke test for the C API. Not wired into CMake — build with:
//   clang++ -std=c++11 -Iinclude test/capi_smoke.cpp build/libSimpleNESCore.a -o capi_smoke
// then: ./capi_smoke path/to/rom.nes

#include "simplenes_core.h"

#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s <rom.nes>\n", argv[0]);
        return 1;
    }

    printf("Frame size: %d x %d\n", sn_frame_width(), sn_frame_height());
    printf("Audio input rate: %d Hz, output rate: %d Hz\n",
           sn_emulator_audio_input_rate(),
           sn_emulator_audio_output_rate());

    sn_emulator* emu = sn_emulator_create();
    if (!emu)
    {
        fprintf(stderr, "sn_emulator_create failed\n");
        return 1;
    }

    if (sn_emulator_load_rom_file(emu, argv[1]) != 0)
    {
        fprintf(stderr, "load ROM failed: %s\n", argv[1]);
        sn_emulator_destroy(emu);
        return 1;
    }

    if (sn_emulator_reset(emu) != 0)
    {
        fprintf(stderr, "reset failed\n");
        sn_emulator_destroy(emu);
        return 1;
    }

    // Run ~1 second (60 NES frames) and pull audio periodically to drain the queue.
    float audio_buf[4096];
    for (int i = 0; i < 60; ++i)
    {
        sn_emulator_step_frame(emu);
        (void)sn_emulator_pull_audio(emu, audio_buf, 4096);
    }

    const uint32_t* fb = sn_emulator_framebuffer(emu);
    if (!fb)
    {
        fprintf(stderr, "framebuffer null\n");
        sn_emulator_destroy(emu);
        return 1;
    }

    // Print a checksum of the framebuffer as a sanity signal — if the emulator ran, some pixels
    // should have been drawn and this should not be zero (unless the ROM starts on a solid black
    // background, which is uncommon).
    uint32_t sum = 0;
    for (int i = 0; i < sn_frame_width() * sn_frame_height(); ++i)
        sum ^= fb[i];
    printf("Framebuffer XOR checksum: 0x%08x\n", sum);
    printf("First pixel (RGBA bytes): 0x%08x\n", fb[0]);

    sn_emulator_destroy(emu);
    printf("OK\n");
    return 0;
}
