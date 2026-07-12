#ifndef COREEMULATOR_H
#define COREEMULATOR_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "APU/APU.h"
#include "APU/Constants.h"
#include "APU/spsc.hpp"
#include "CPU.h"
#include "Cartridge.h"
#include "Controller.h"
#include "MainBus.h"
#include "Mapper.h"
#include "PPU.h"
#include "PictureBus.h"
#include "VirtualScreen.h"

namespace sn
{
// Cycles the CPU runs per rendered NES frame at NTSC (~60 Hz). Public so both CoreEmulator and any
// host that wants to advance one frame worth of work can reference the same constant.
constexpr int kCpuCyclesPerFrame = 29781;

// Headless NES core. Owns every hardware component (CPU/PPU/APU/Mapper/Bus/Controllers) and the
// output framebuffer + audio sample queue, but knows nothing about SFML, miniaudio, iOS, or any
// specific host. Hosts drive it by calling stepCycle()/stepFrame(), read pixels from
// screen().pixels(), pull samples from audioQueue(), and push controller input via controller(idx).
//
// Split out from the old sn::Emulator (which now becomes a thin SFML host on top of this).
class CoreEmulator
{
public:
    // Default output sample rate handed to APU — matches what the desktop AudioPlayer already
    // configures miniaudio for. Only used to initialize APU's (unused) sampling_timer at present.
    static constexpr int kDefaultAudioOutputSampleRate = 44100;

    CoreEmulator();
    ~CoreEmulator() = default;

    // ROM loading — false on failure. On success the caller MUST call reset() before stepping.
    bool loadROMFile(const std::string& path);
    bool loadROMMemory(const std::uint8_t* data, std::size_t len);

    // Prepare CPU + PPU for execution. Must be called after a successful load and before any step.
    // Returns false if there is no loaded ROM to bind to.
    bool reset();

    // Advance the emulator by exactly one CPU cycle (which itself drives 3 PPU cycles and 1 APU cycle).
    // Kept as a public step primitive so hosts that need sub-frame granularity (elapsed-time-driven
    // desktop loop) can still work at the original cadence.
    void stepCycle();

    // Advance one full NES frame. Semantically equivalent to `for (int i=0; i<kCpuCyclesPerFrame; ++i) stepCycle()`.
    void stepFrame();

    // Video output — a 256x240 RGBA8 framebuffer (bytes in R,G,B,A order) updated every frame.
    const VirtualScreen& screen() const { return m_screen; }

    // Controller access — idx 0 = player 1, idx 1 = player 2. Hosts push button state whenever they
    // sample their input source (once per frame is enough for most games).
    Controller&       controller(int idx) { return idx == 0 ? m_controller1 : m_controller2; }
    const Controller& controller(int idx) const { return idx == 0 ? m_controller1 : m_controller2; }

    // Audio — mono float samples produced at the APU's downsampled output rate (see
    // audioOutputSampleRate()). The queue is SPSC: this emulator is the sole writer,
    // the host's audio callback must be the sole reader.
    spsc::RingBuffer<float>&       audioQueue() { return m_audio_queue; }
    const spsc::RingBuffer<float>& audioQueue() const { return m_audio_queue; }
    int                            audioOutputSampleRate() const { return m_audio_output_sample_rate; }

    // Battery-backed cartridge RAM ("SRAM") access. Non-zero size only for ROMs whose iNES header
    // sets the battery / persistent-memory bit (byte 6 bit 1). Hosts persist the returned buffer
    // to disk on shutdown / background / reset and restore it after loadROM* + reset() so cartridge
    // saves (Zelda passwords, Final Fantasy party, etc.) survive.
    //
    // Buffer identity is stable between reset() calls (see reset() below — the emulator preserves
    // the bytes across mapper re-creation to mirror real-hardware behavior: pressing Reset does
    // not clear battery memory). Pointer itself may change after reset(); always re-fetch.
    std::size_t    sramSize() const;
    const std::uint8_t* sramData() const;
    // Overwrite up to sramSize() bytes into the live SRAM buffer. Returns number of bytes actually
    // copied (0 if sramSize()==0 or data==nullptr). Intended to be called immediately after a
    // successful reset() to restore a persisted save.
    std::size_t    setSRAMData(const std::uint8_t* data, std::size_t len);

private:
    void OAMDMA(Byte page);
    Byte DMCDMA(Address addr);

    CPU                     m_cpu;
    PictureBus              m_pictureBus;
    PPU                     m_ppu;
    // Queue is declared before m_apu because m_apu's constructor takes a reference to it.
    spsc::RingBuffer<float> m_audio_queue;
    int                     m_audio_output_sample_rate;
    APU                     m_apu;
    Cartridge               m_cartridge;
    std::unique_ptr<Mapper> m_mapper;
    Controller              m_controller1;
    Controller              m_controller2;
    MainBus                 m_bus;
    VirtualScreen           m_screen;

    bool                    m_hasROM = false;
};
}

#endif // COREEMULATOR_H
