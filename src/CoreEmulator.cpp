#include "CoreEmulator.h"

#include "APU/Constants.h"
#include "LastError.h"
#include "Log.h"

#include <sstream>

namespace sn
{
namespace
{
// Approximate sample rate the APU produces (samples pushed once every 2 CPU cycles). Historically
// wired through AudioPlayer::input_sample_rate; here we compute it directly from the CPU period so
// CoreEmulator has no host dependency.
int apu_input_sample_rate()
{
    // apu_clock_period_s = 2 * cpu_clock_period_s ~ 1118 ns → ~894886 Hz.
    // Match the exact integer-cast the old AudioPlayer used to keep sample counts identical.
    return static_cast<int>(1.0 / apu_clock_period_s.count());
}

// Ring buffer capacity in samples. Matches the sizing formula the previous AudioPlayer used:
//   4 * input_rate * (callback_period_ms/100)  (integer arithmetic, ~120ms callback)
// so the desktop host sees the same buffering behavior after this refactor.
std::size_t audio_queue_capacity()
{
    return static_cast<std::size_t>(4) * static_cast<std::size_t>(apu_input_sample_rate()) *
           static_cast<std::size_t>(120 / 100);
}
}

CoreEmulator::CoreEmulator()
  : m_cpu(m_bus)
  , m_ppu(m_pictureBus, m_screen)
  , m_audio_queue(static_cast<int>(audio_queue_capacity()))
  , m_audio_output_sample_rate(kDefaultAudioOutputSampleRate)
  , m_apu(m_audio_queue, m_audio_output_sample_rate, m_cpu.createIRQHandler(),
          [&](Address addr) { return DMCDMA(addr); })
  , m_bus(m_ppu, m_apu, m_controller1, m_controller2, [&](Byte b) { OAMDMA(b); })
{
    m_ppu.setInterruptCallback([&]() { m_cpu.nmiInterrupt(); });
    // Allocate the 256x240 RGBA framebuffer up front so screen().pixels() is valid immediately.
    // The desktop code used to do this in Emulator::run() right before creating the SFML texture;
    // now the core owns it since it's not display-library-specific.
    m_screen.create(ScanlineVisibleDots, VisibleScanlines);
}

bool CoreEmulator::loadROMFile(const std::string& path)
{
    setLastError("");
    if (!m_cartridge.loadFromFile(path))
    {
        m_hasROM = false;
        return false;
    }
    m_hasROM = true;
    return true;
}

bool CoreEmulator::loadROMMemory(const std::uint8_t* data, std::size_t len)
{
    setLastError("");
    if (!m_cartridge.loadFromMemory(data, len))
    {
        m_hasROM = false;
        return false;
    }
    m_hasROM = true;
    return true;
}

bool CoreEmulator::reset()
{
    setLastError("");
    if (!m_hasROM)
    {
        setLastError("reset() called without a loaded ROM");
        LOG(Error) << "CoreEmulator::reset() called without a loaded ROM" << std::endl;
        return false;
    }

    m_mapper = Mapper::createMapper(static_cast<Mapper::Type>(m_cartridge.getMapper()),
                                    m_cartridge,
                                    m_cpu.createIRQHandler(),
                                    [&]() { m_pictureBus.updateMirroring(); });
    if (!m_mapper)
    {
        std::ostringstream ss;
        ss << "Unsupported mapper #" << +m_cartridge.getMapper()
           << " (supported: 0, 1, 2, 3, 4, 7, 11, 66)";
        setLastError(ss.str());
        LOG(Error) << ss.str() << std::endl;
        return false;
    }

    if (!m_bus.setMapper(m_mapper.get()) || !m_pictureBus.setMapper(m_mapper.get()))
    {
        return false;
    }

    m_cpu.reset();
    m_ppu.reset();
    return true;
}

void CoreEmulator::stepCycle()
{
    // Same 3:1:1 ordering the desktop main loop has always used — see CLAUDE.md.
    m_ppu.step();
    m_ppu.step();
    m_ppu.step();
    m_cpu.step();
    m_apu.step();
}

void CoreEmulator::stepFrame()
{
    for (int i = 0; i < kCpuCyclesPerFrame; ++i)
    {
        stepCycle();
    }
}

void CoreEmulator::OAMDMA(Byte page)
{
    m_cpu.skipOAMDMACycles();
    auto page_ptr = m_bus.getPagePtr(page);
    if (page_ptr != nullptr)
    {
        m_ppu.doDMA(page_ptr);
    }
    else
    {
        LOG(Error) << "Can't get pageptr for DMA" << std::endl;
    }
}

Byte CoreEmulator::DMCDMA(Address addr)
{
    m_cpu.skipDMCDMACycles();
    return m_bus.read(addr);
}
}
