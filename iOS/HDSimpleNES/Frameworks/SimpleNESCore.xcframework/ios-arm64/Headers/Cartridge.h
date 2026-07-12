#ifndef CARTRIDGE_H
#define CARTRIDGE_H
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace sn
{
using Byte    = std::uint8_t;
using Address = std::uint16_t;

class Cartridge
{
public:
    Cartridge();
    bool                     loadFromFile(std::string path);
    // Load an iNES ROM already resident in memory. Same parsing as loadFromFile — the file version
    // is now a thin wrapper that reads the file into a buffer and calls this. Preferred by hosts
    // (iOS, tests, sandboxed environments) that get their ROM bytes from something other than a
    // plain filesystem path.
    bool                     loadFromMemory(const Byte* data, std::size_t len);
    const std::vector<Byte>& getROM();
    const std::vector<Byte>& getVROM();
    Byte                     getMapper();
    Byte                     getNameTableMirroring();
    bool                     hasExtendedRAM();
    // iNES header byte-6 bit-1 as parsed at load time. "Battery-backed RAM present at
    // $6000-$7FFF" — the real cartridge-persistent-memory flag, as distinct from
    // hasExtendedRAM() which is always-true because some ROMs mis-set the bit and the
    // emulator has no cost to unconditionally allocating an 8 KB scratch page. Hosts
    // gating save-file creation should read this one.
    bool                     hasBatteryRAM() const { return m_extendedRAM; }

private:
    // IEEE 802.3 reflected CRC32. Used for the known-bad-header override table in loadFromMemory.
    static std::uint32_t crc32(const Byte* data, std::size_t len);

    std::vector<Byte> m_PRG_ROM;
    std::vector<Byte> m_CHR_ROM;
    Byte              m_nameTableMirroring;
    Byte              m_mapperNumber;
    bool              m_extendedRAM;
    bool              m_chrRAM;
};

};

#endif // CARTRIDGE_H
