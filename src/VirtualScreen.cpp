#include "VirtualScreen.h"

namespace sn
{
void VirtualScreen::create(unsigned int w, unsigned int h)
{
    m_width  = w;
    m_height = h;
    m_pixels.assign(static_cast<std::size_t>(w) * h, 0u);
}

void VirtualScreen::setPixel(std::size_t x, std::size_t y, std::uint32_t rgba)
{
    if (x >= m_width || y >= m_height)
        return;
    m_pixels[y * m_width + x] = rgba;
}
}
