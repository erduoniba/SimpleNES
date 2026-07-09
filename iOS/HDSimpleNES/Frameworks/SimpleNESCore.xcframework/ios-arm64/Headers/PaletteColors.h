#ifndef PALETTECOLORS_H
#define PALETTECOLORS_H

#include <cstdint>

namespace sn
{
// Palette entries are written below in the conventional 0xRRGGBBAA hex form so they stay easy to
// eyeball against reference palettes. The renderer uploads the picture buffer as raw bytes to a
// texture that expects them in [R, G, B, A] memory order, so we repack each 32-bit value at
// compile time into an integer whose little-endian byte layout IS [R, G, B, A]. All build targets
// (x86 / arm64 on macOS / Linux / Windows / iOS) are little-endian; a static_assert guards it.
constexpr std::uint32_t rgba_le(std::uint32_t v)
{
    // Input:  0xRRGGBBAA  (byte order: R=[31:24], G=[23:16], B=[15:8], A=[7:0])
    // Output on LE: uint32_t whose byte 0 = R, byte 1 = G, byte 2 = B, byte 3 = A
    return ((v >> 24) & 0xffu)         // R -> byte 0 -> bits [7:0]
         | (((v >> 16) & 0xffu) << 8)  // G -> byte 1
         | (((v >>  8) & 0xffu) << 16) // B -> byte 2
         | (((v >>  0) & 0xffu) << 24); // A -> byte 3
}

// Colors in RGBA (8 bit colors)
constexpr std::uint32_t colors[] = {
    rgba_le(0x666666ff), rgba_le(0x002a88ff), rgba_le(0x1412a7ff), rgba_le(0x3b00a4ff),
    rgba_le(0x5c007eff), rgba_le(0x6e0040ff), rgba_le(0x6c0600ff), rgba_le(0x561d00ff),
    rgba_le(0x333500ff), rgba_le(0x0b4800ff), rgba_le(0x005200ff), rgba_le(0x004f08ff),
    rgba_le(0x00404dff), rgba_le(0x000000ff), rgba_le(0x000000ff), rgba_le(0x000000ff),
    rgba_le(0xadadadff), rgba_le(0x155fd9ff), rgba_le(0x4240ffff), rgba_le(0x7527feff),
    rgba_le(0xa01accff), rgba_le(0xb71e7bff), rgba_le(0xb53120ff), rgba_le(0x994e00ff),
    rgba_le(0x6b6d00ff), rgba_le(0x388700ff), rgba_le(0x0c9300ff), rgba_le(0x008f32ff),
    rgba_le(0x007c8dff), rgba_le(0x000000ff), rgba_le(0x000000ff), rgba_le(0x000000ff),
    rgba_le(0xfffeffff), rgba_le(0x64b0ffff), rgba_le(0x9290ffff), rgba_le(0xc676ffff),
    rgba_le(0xf36affff), rgba_le(0xfe6eccff), rgba_le(0xfe8170ff), rgba_le(0xea9e22ff),
    rgba_le(0xbcbe00ff), rgba_le(0x88d800ff), rgba_le(0x5ce430ff), rgba_le(0x45e082ff),
    rgba_le(0x48cddeff), rgba_le(0x4f4f4fff), rgba_le(0x000000ff), rgba_le(0x000000ff),
    rgba_le(0xfffeffff), rgba_le(0xc0dfffff), rgba_le(0xd3d2ffff), rgba_le(0xe8c8ffff),
    rgba_le(0xfbc2ffff), rgba_le(0xfec4eaff), rgba_le(0xfeccc5ff), rgba_le(0xf7d8a5ff),
    rgba_le(0xe4e594ff), rgba_le(0xcfef96ff), rgba_le(0xbdf4abff), rgba_le(0xb3f3ccff),
    rgba_le(0xb5ebf2ff), rgba_le(0xb8b8b8ff), rgba_le(0x000000ff), rgba_le(0x000000ff),
};

// Compile-time sanity check that our targets are little-endian.
static_assert(rgba_le(0x11223344u) == 0x44332211u, "palette repack expects little-endian target");
}

#endif // PALETTECOLORS_H
