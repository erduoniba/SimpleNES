#include "Cartridge.h"
#include "LastError.h"
#include "Log.h"
#include "Mapper.h"
#include <fstream>
#include <sstream>
#include <string>

namespace sn
{
Cartridge::Cartridge()
  : m_nameTableMirroring(0)
  , m_mapperNumber(0)
  , m_extendedRAM(false)
{
}
const std::vector<Byte>& Cartridge::getROM()
{
    return m_PRG_ROM;
}

const std::vector<Byte>& Cartridge::getVROM()
{
    return m_CHR_ROM;
}

Byte Cartridge::getMapper()
{
    return m_mapperNumber;
}

Byte Cartridge::getNameTableMirroring()
{
    return m_nameTableMirroring;
}

bool Cartridge::hasExtendedRAM()
{
    // Some ROMs don't have this set correctly, plus there's no particular reason to disable it.
    return true;
}

bool Cartridge::loadFromFile(std::string path)
{
    std::ifstream romFile(path, std::ios_base::binary | std::ios_base::in);
    if (!romFile)
    {
        setLastError("Could not open ROM file: " + path);
        LOG(Error) << "Could not open ROM file from path: " << path << std::endl;
        return false;
    }

    LOG(Info) << "Reading ROM from path: " << path << std::endl;

    // Slurp the whole ROM into a buffer and defer parsing to loadFromMemory. Keeps the header
    // logic in one place and lets hosts that already have bytes in-memory (iOS from NSData, tests)
    // reuse the same parser without touching the filesystem.
    romFile.seekg(0, std::ios::end);
    std::streamsize size = romFile.tellg();
    if (size <= 0)
    {
        setLastError("ROM file is empty: " + path);
        LOG(Error) << "ROM file appears empty: " << path << std::endl;
        return false;
    }
    romFile.seekg(0, std::ios::beg);

    std::vector<Byte> buffer(static_cast<std::size_t>(size));
    if (!romFile.read(reinterpret_cast<char*>(buffer.data()), size))
    {
        setLastError("Failed to read ROM file: " + path);
        LOG(Error) << "Failed to read ROM file: " << path << std::endl;
        return false;
    }

    return loadFromMemory(buffer.data(), buffer.size());
}

bool Cartridge::loadFromMemory(const Byte* data, std::size_t len)
{
    if (data == nullptr || len < 0x10)
    {
        std::ostringstream ss;
        ss << "ROM too small: need >= 16 bytes for iNES header, got " << len;
        setLastError(ss.str());
        LOG(Error) << ss.str() << std::endl;
        return false;
    }

    // Header
    const Byte* header = data;
    if (std::string { reinterpret_cast<const char*>(&header[0]), reinterpret_cast<const char*>(&header[4]) } !=
        "NES\x1A")
    {
        std::ostringstream ss;
        ss << "Not an iNES ROM (magic bytes " << std::hex << +header[0] << " " << +header[1] << " "
           << +header[2] << " " << +header[3] << ")";
        setLastError(ss.str());
        LOG(Error) << ss.str() << std::endl;
        return false;
    }

    LOG(Info) << "Reading header, it dictates: \n";

    Byte banks = header[4];
    LOG(Info) << "16KB PRG-ROM Banks: " << +banks << std::endl;
    if (!banks)
    {
        setLastError("ROM has no PRG-ROM banks");
        LOG(Error) << "ROM has no PRG-ROM banks. Loading ROM failed." << std::endl;
        return false;
    }

    Byte vbanks = header[5];
    LOG(Info) << "8KB CHR-ROM Banks: " << +vbanks << std::endl;

    if (header[6] & 0x8)
    {
        m_nameTableMirroring = NameTableMirroring::FourScreen;
        LOG(Info) << "Name Table Mirroring: " << "FourScreen" << std::endl;
    }
    else
    {
        m_nameTableMirroring = header[6] & 0x1;
        LOG(Info) << "Name Table Mirroring: " << (m_nameTableMirroring == 0 ? "Horizontal" : "Vertical") << std::endl;
    }

    // Dirty-header heuristic. Many iNES 1.0 dumps floating around (Chinese fan-translations
    // especially — this Zelda 汉化版 was one) stored the dumper's name / copyright as ASCII text in
    // bytes 7-15. Blindly reading `header[7] & 0xf0` as the mapper high nibble then produces absurd
    // mapper numbers (245, etc.) and the ROM gets rejected.
    //
    // Standard heuristic (NESdev wiki "iNES", also what FCEUX / Mesen do):
    //   - NES 2.0 → header[7] bits 2-3 == 0b10. Trust the full mapper field.
    //   - Clean iNES 1.0 → bytes 12-15 all zero. Trust header[7]'s high nibble.
    //   - Anything else (bytes 12-15 have data) → archaic / dirty iNES. Use only header[6]'s
    //     high nibble, ignore header[7]'s high nibble entirely.
    //
    // This still can't rescue ROMs whose header[6] low nibble is ALSO garbage (some Chinese pirate
    // dumps corrupt both). Those surface as "Unsupported mapper #N" which is the honest answer —
    // the header genuinely doesn't describe a mapper we implement.
    const bool is_nes2 = (header[7] & 0x0C) == 0x08;
    const bool tail_zero =
      (header[12] == 0 && header[13] == 0 && header[14] == 0 && header[15] == 0);
    if (is_nes2 || tail_zero)
    {
        m_mapperNumber = ((header[6] >> 4) & 0xf) | (header[7] & 0xf0);
    }
    else
    {
        m_mapperNumber = (header[6] >> 4) & 0xf;
        LOG(Info) << "Dirty iNES header (bytes 12-15 non-zero) — ignoring header[7] high nibble (raw "
                  << std::hex << +header[7] << std::dec << ")." << std::endl;
    }
    LOG(Info) << "Mapper #: " << +m_mapperNumber << std::endl;

    m_extendedRAM = header[6] & 0x2;
    LOG(Info) << "Extended (CPU) RAM: " << std::boolalpha << m_extendedRAM << std::endl;

    if (header[6] & 0x4)
    {
        // Trainer present: 512 bytes between the 16-byte header and the first PRG-ROM bank. Common
        // in patched / translated ROMs (Chinese-fan-translated JRPGs especially). The trainer used
        // to be loaded to $7000, but modern mappers with battery-RAM at $6000 make it useless, and
        // most emulators just skip it. We do the same.
        LOG(Info) << "Trainer detected — skipping 512 bytes." << std::endl;
    }
    const std::size_t trainer_size = (header[6] & 0x4) ? 512 : 0;

    if ((header[0xA] & 0x3) == 0x2 || (header[0xA] & 0x1))
    {
        setLastError("PAL ROM not supported (NTSC only)");
        LOG(Error) << "PAL ROM not supported." << std::endl;
        return false;
    }
    else
        LOG(Info) << "ROM is NTSC compatible.\n";

    // PRG-ROM 16KB banks
    const std::size_t prg_size = static_cast<std::size_t>(0x4000) * banks;
    const std::size_t chr_size = static_cast<std::size_t>(0x2000) * vbanks;
    const std::size_t needed   = 0x10 + trainer_size + prg_size + chr_size;
    if (len < needed)
    {
        std::ostringstream ss;
        ss << "ROM truncated: expected " << needed << " bytes, got " << len
           << " (mapper " << +m_mapperNumber << ", " << +banks << "x16KB PRG, " << +vbanks << "x8KB CHR"
           << (trainer_size ? ", trainer" : "") << ")";
        setLastError(ss.str());
        LOG(Error) << ss.str() << std::endl;
        return false;
    }

    const std::size_t prg_offset = 0x10 + trainer_size;
    m_PRG_ROM.assign(data + prg_offset, data + prg_offset + prg_size);

    if (vbanks)
    {
        const std::size_t chr_offset = prg_offset + prg_size;
        m_CHR_ROM.assign(data + chr_offset, data + chr_offset + chr_size);
    }
    else
    {
        LOG(Info) << "Cartridge with CHR-RAM." << std::endl;
        m_CHR_ROM.clear();
    }

    // Known-bad-header override. Some dumps (Chinese pirate / fan-translation ROMs) have header
    // corruption that no header-only heuristic can fix — both `header[6]` low nibble AND
    // `header[7]` high nibble may be garbage. The industry-standard workaround (Mesen / FCEUX /
    // NesCartDB) is to look up the PRG payload's CRC32 in a small database and override the mapper
    // for known dumps.
    //
    // Table is intentionally empty right now. When you find a specific ROM you want to rescue,
    // add a { crc, mapper, mirroring, "name" } entry — verified by actually running it and seeing
    // graphics on screen, not by guessing from a header dump.
    //
    // CRC32 uses the IEEE 802.3 reflected polynomial (0xEDB88320), same variant zlib publishes.
    struct HeaderOverride
    {
        std::uint32_t prg_crc32;
        Byte          mapper;
        Byte          mirroring;      // 0 = horizontal, 1 = vertical, 8 = four-screen
        const char*   description;
    };
    static const HeaderOverride overrides[] = {
        // Empty — add verified entries here.
        { 0, 0, 0, nullptr },
    };
    const std::uint32_t prg_crc = crc32(m_PRG_ROM.data(), m_PRG_ROM.size());
    for (const auto& o : overrides)
    {
        if (o.description == nullptr) continue;  // sentinel skip
        if (o.prg_crc32 == prg_crc)
        {
            LOG(Info) << "Known-bad-header override: PRG CRC32 0x" << std::hex << prg_crc
                      << std::dec << " → mapper " << +o.mapper << " (" << o.description << ")"
                      << std::endl;
            m_mapperNumber       = o.mapper;
            m_nameTableMirroring = o.mirroring;
            break;
        }
    }

    return true;
}

// CRC32 with IEEE 802.3 reflected polynomial (0xEDB88320). Table generated lazily on first call.
// Kept private to this file — the only consumer is the known-bad-header override above.
std::uint32_t Cartridge::crc32(const Byte* data, std::size_t len)
{
    static std::uint32_t table[256];
    static bool          initialized = false;
    if (!initialized)
    {
        for (std::uint32_t i = 0; i < 256; ++i)
        {
            std::uint32_t c = i;
            for (int j = 0; j < 8; ++j)
                c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        initialized = true;
    }
    std::uint32_t crc = 0xFFFFFFFFu;
    for (std::size_t i = 0; i < len; ++i)
        crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}
}
