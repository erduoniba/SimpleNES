#include "CoreEmulator.h"

#include "APU/Constants.h"
#include "LastError.h"
#include "Log.h"

#include <algorithm>
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

    // Battery-backed cartridge RAM must survive soft-reset (real hardware keeps it powered
    // independently of the reset line). Snapshot the live SRAM before we tear the mapper down,
    // create the fresh mapper, then splat the bytes back so games like Zelda / Final Fantasy /
    // Kirby's Adventure don't lose their saves when the user hits the Reset button.
    std::vector<std::uint8_t> sram_snapshot;
    if (m_mapper)
    {
        const std::size_t sz = sramSize();
        if (sz > 0)
        {
            const std::uint8_t* src = sramData();
            if (src != nullptr)
            {
                sram_snapshot.assign(src, src + sz);
            }
        }
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

    // Restore snapshotted SRAM into whatever buffer the new mapper/bus expose. If the size
    // shrank (unlikely — same ROM re-mapped identically) we truncate; if it grew we leave the
    // tail zero-initialized.
    if (!sram_snapshot.empty())
    {
        setSRAMData(sram_snapshot.data(), sram_snapshot.size());
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

// SRAM access. Priority order: mapper-owned buffer first (MMC3), MainBus-owned buffer second
// (SxROM/CNROM/AxROM/etc. that route $6000-$7FFF through MainBus::m_extRAM).
//
// We gate the MainBus fallback on Cartridge::hasBatteryRAM() (the true iNES byte-6 bit-1
// value) because MainBus unconditionally allocates 8 KB of scratch RAM for every mapper —
// see Cartridge::hasExtendedRAM() which always returns true. Without this gate every
// non-battery ROM would appear to have 8 KB of save state, and hosts would create empty
// .sram files for Battle City, Super Mario Bros, etc. The mapper-owned path (MMC3) is not
// gated: those mappers only allocate PRG-RAM when the mapper itself needs it, and MMC3's
// 32 KB buffer is only interesting when the header battery bit is also set — but we still
// let it through because a mapper that decides to expose SRAM is authoritative.
std::size_t CoreEmulator::sramSize() const
{
    if (!m_mapper) return 0;
    if (m_mapper->sramData() != nullptr && m_mapper->sramSize() > 0)
    {
        return m_mapper->sramSize();
    }
    if (!m_cartridge.hasBatteryRAM()) return 0;
    return m_bus.extRAMSize();
}

const std::uint8_t* CoreEmulator::sramData() const
{
    if (!m_mapper) return nullptr;
    if (const std::uint8_t* mp = m_mapper->sramData())
    {
        if (m_mapper->sramSize() > 0) return mp;
    }
    if (!m_cartridge.hasBatteryRAM()) return nullptr;
    return m_bus.extRAMData();
}

std::size_t CoreEmulator::setSRAMData(const std::uint8_t* data, std::size_t len)
{
    if (!m_mapper || data == nullptr || len == 0) return 0;

    // Prefer the mapper-owned buffer if it exists.
    if (Byte* mp = m_mapper->sramData())
    {
        const std::size_t sz = m_mapper->sramSize();
        if (sz > 0)
        {
            const std::size_t n = len < sz ? len : sz;
            std::copy(data, data + n, mp);
            return n;
        }
    }
    if (!m_cartridge.hasBatteryRAM()) return 0;
    if (Byte* bp = m_bus.extRAMData())
    {
        const std::size_t sz = m_bus.extRAMSize();
        if (sz > 0)
        {
            const std::size_t n = len < sz ? len : sz;
            std::copy(data, data + n, bp);
            return n;
        }
    }
    return 0;
}
}
