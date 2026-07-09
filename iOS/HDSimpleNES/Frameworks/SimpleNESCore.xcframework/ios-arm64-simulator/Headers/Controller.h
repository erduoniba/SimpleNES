#ifndef CONTROLLER_H
#define CONTROLLER_H
#include <array>
#include <cstdint>

namespace sn
{
using Byte = std::uint8_t;

// NES standard controller. The class is decoupled from any input backend: the host is expected to
// sample its input source once per frame (or more) and push the pressed/released state of each
// button in through setButtonState(). strobe()/read() implement the 0x4016/0x4017 shift-register
// protocol the CPU sees.
class Controller
{
public:
    Controller();
    enum Buttons
    {
        A,
        B,
        Select,
        Start,
        Up,
        Down,
        Left,
        Right,
        TotalButtons,
    };

    void strobe(Byte b);
    Byte read();

    // Host-driven input surface. Call whenever the input state changes (typically once per emulated
    // frame). Values persist until overwritten.
    void setButtonState(Buttons button, bool pressed);

private:
    bool                              m_strobe;
    unsigned int                      m_keyStates;

    std::array<bool, TotalButtons>    m_buttonStates;
};
}

#endif // CONTROLLER_H
