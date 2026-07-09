#ifndef VIRTUALSCREEN_H
#define VIRTUALSCREEN_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace sn
{
// Framebuffer for the PPU's output. Stores one 32-bit pixel per NES output pixel in RGBA byte
// order (compatible with sf::Texture::update, Metal's MTLPixelFormatRGBA8Unorm, etc). The host
// pulls the raw buffer via pixels() and hands it to whatever renderer it uses; VirtualScreen itself
// has no display-library dependency.
class VirtualScreen
{
public:
    void                        create(unsigned int width, unsigned int height);
    void                        setPixel(std::size_t x, std::size_t y, std::uint32_t rgba);

    const std::uint32_t*        pixels() const { return m_pixels.data(); }
    unsigned int                width() const { return m_width; }
    unsigned int                height() const { return m_height; }

private:
    unsigned int                m_width  = 0;
    unsigned int                m_height = 0;
    std::vector<std::uint32_t>  m_pixels;
};
}
#endif // VIRTUALSCREEN_H
