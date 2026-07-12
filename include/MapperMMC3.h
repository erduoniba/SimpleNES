#pragma once
#include "IRQ.h"
#include "Mapper.h"
#include <array>

namespace sn
{

class MapperMMC3 : public Mapper
{
public:
    MapperMMC3(Cartridge& cart, IRQHandle& irq, std::function<void(void)> mirroring_cb);

    Byte               readPRG(Address addr);
    void               writePRG(Address addr, Byte value);

    NameTableMirroring getNameTableMirroring();
    Byte               readCHR(Address addr);
    void               writeCHR(Address addr, Byte value);

    void               scanlineIRQ();

    // MMC3's PRG-RAM lives inside the mapper (not on the bus), so expose it to the host for
    // battery-save snapshotting. See Mapper::sramData() base contract.
    Byte*              sramData() override { return m_prgRam.data(); }
    const Byte*        sramData() const override { return m_prgRam.data(); }
    std::size_t        sramSize() const override { return m_prgRam.size(); }

private:
    // Control variables
    uint32_t                  m_targetRegister;
    bool                      m_prgBankMode;
    bool                      m_chrInversion;

    uint32_t                  m_bankRegister[8];

    bool                      m_irqEnabled;
    Byte                      m_irqCounter;
    Byte                      m_irqLatch;
    bool                      m_irqReloadPending;

    std::vector<Byte>         m_prgRam;
    std::vector<Byte>         m_mirroringRam;
    const Byte*               m_prgBank0;
    const Byte*               m_prgBank1;
    const Byte*               m_prgBank2;
    const Byte*               m_prgBank3;

    std::array<uint32_t, 8>   m_chrBanks;

    NameTableMirroring        m_mirroring;
    std::function<void(void)> m_mirroringCallback;
    IRQHandle&                m_irq;
};

} // namespace sn
