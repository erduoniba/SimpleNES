#include "Controller.h"

namespace sn
{
Controller::Controller()
  : m_strobe(false)
  , m_keyStates(0)
  , m_buttonStates {}
{
}

void Controller::setButtonState(Buttons button, bool pressed)
{
    m_buttonStates[button] = pressed;
}

void Controller::strobe(Byte b)
{
    m_strobe = (b & 1);
    if (!m_strobe)
    {
        m_keyStates = 0;
        int shift   = 0;
        for (int button = A; button < TotalButtons; ++button)
        {
            m_keyStates |= (static_cast<unsigned int>(m_buttonStates[button]) << shift);
            ++shift;
        }
    }
}

Byte Controller::read()
{
    Byte ret;
    if (m_strobe)
        ret = m_buttonStates[A] ? 1 : 0;
    else
    {
        ret           = (m_keyStates & 1);
        m_keyStates >>= 1;
    }
    return ret | 0x40;
}

}
