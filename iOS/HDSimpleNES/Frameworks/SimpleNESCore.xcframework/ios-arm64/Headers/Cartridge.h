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
