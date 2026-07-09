#include "Emulator.h"
#include "APU/Constants.h"
#include "Log.h"

#include <chrono>

namespace sn
{
using std::chrono::high_resolution_clock;

Emulator::Emulator()
  : m_core()
  , m_audioPlayer(m_core.audioQueue(), static_cast<int>(1.0 / apu_clock_period_s.count()))
  , m_screenScale(3.f)
  , m_p1Keys(Controller::TotalButtons, sf::Keyboard::Unknown)
  , m_p2Keys(Controller::TotalButtons, sf::Keyboard::Unknown)
  , m_lastWakeup()
{
}

void Emulator::pollInput()
{
    // Push the current SFML keyboard state into both core controllers, once per frame.
    // The core is decoupled from SFML — this function is the only translation point.
    auto push = [](Controller& c, const std::vector<sf::Keyboard::Key>& keys) {
        for (int b = Controller::A; b < Controller::TotalButtons; ++b)
        {
            auto btn     = static_cast<Controller::Buttons>(b);
            bool pressed = keys[b] != sf::Keyboard::Unknown && sf::Keyboard::isKeyPressed(keys[b]);
            c.setButtonState(btn, pressed);
        }
    };
    push(m_core.controller(0), m_p1Keys);
    push(m_core.controller(1), m_p2Keys);
}

void Emulator::run(std::string rom_path)
{
    if (!m_core.loadROMFile(rom_path))
        return;
    if (!m_core.reset())
        return;

    m_window.create(sf::VideoMode(NESVideoWidth * m_screenScale, NESVideoHeight * m_screenScale),
                    "SimpleNES",
                    sf::Style::Titlebar | sf::Style::Close);
    m_window.setVerticalSyncEnabled(true);

    // Set up the texture the PPU draws into. NES output is 256x240 RGBA8 and we upload the whole
    // buffer once per rendered frame — cheaper than the previous 61440-vertex mesh.
    if (!m_frameTexture.create(NESVideoWidth, NESVideoHeight))
    {
        LOG(Error) << "Failed to create frame texture." << std::endl;
        return;
    }
    m_frameSprite.setTexture(m_frameTexture, true);
    m_frameSprite.setScale(m_screenScale, m_screenScale);

    m_lastWakeup  = high_resolution_clock::now();
    m_elapsedTime = m_lastWakeup - m_lastWakeup;

    m_audioPlayer.start();

    sf::Event event;
    bool      focus = true, pause = false;
    while (m_window.isOpen())
    {
        while (m_window.pollEvent(event))
        {
            if (event.type == sf::Event::Closed ||
                (event.type == sf::Event::KeyPressed && event.key.code == sf::Keyboard::Escape))
            {
                m_window.close();
                return;
            }
            else if (event.type == sf::Event::GainedFocus)
            {
                focus          = true;
                const auto now = high_resolution_clock::now();
                LOG(Info) << "Gained focus. Removing " << (now - m_lastWakeup).count() << "ns from timers" << std::endl;
                m_lastWakeup = now;
            }
            else if (event.type == sf::Event::LostFocus)
            {
                focus = false;
                LOG(Info) << "Losing focus; paused." << std::endl;
            }
            else if (event.type == sf::Event::KeyPressed && event.key.code == sf::Keyboard::F2)
            {
                pause = !pause;
                if (!pause)
                {
                    const auto now = high_resolution_clock::now();
                    LOG(Info) << "Unpaused. Removing " << (now - m_lastWakeup).count() << "ns from timers" << std::endl;
                    m_lastWakeup = now;
                }
                else
                {
                    LOG(Info) << "Paused." << std::endl;
                }
            }
            else if (pause && event.type == sf::Event::KeyReleased && event.key.code == sf::Keyboard::F3)
            {
                m_core.stepFrame();
            }
            else if (focus && event.type == sf::Event::KeyReleased && event.key.code == sf::Keyboard::F4)
            {
                Log::get().setLevel(Info);
            }
            else if (focus && event.type == sf::Event::KeyReleased && event.key.code == sf::Keyboard::F5)
            {
                Log::get().setLevel(InfoVerbose);
            }
        }

        if (focus && !pause)
        {
            pollInput();

            const auto now  = high_resolution_clock::now();
            m_elapsedTime  += now - m_lastWakeup;
            m_lastWakeup    = now;

            while (m_elapsedTime > cpu_clock_period_ns)
            {
                m_core.stepCycle();
                m_elapsedTime -= cpu_clock_period_ns;
            }

            // Upload the freshly-rendered NES framebuffer into the GPU texture and blit it. update()
            // takes bytes in [R,G,B,A] order and our PaletteColors are pre-packed to match on LE.
            m_frameTexture.update(reinterpret_cast<const sf::Uint8*>(m_core.screen().pixels()));
            m_window.draw(m_frameSprite);
            m_window.display();
        }
        else
        {
            sf::sleep(sf::milliseconds(1000 / 60));
        }
    }
}

void Emulator::setVideoHeight(int height)
{
    m_screenScale = height / float(NESVideoHeight);
    LOG(Info) << "Scale: " << m_screenScale << " set. Screen: " << int(NESVideoWidth * m_screenScale) << "x"
              << int(NESVideoHeight * m_screenScale) << std::endl;
}

void Emulator::setVideoWidth(int width)
{
    m_screenScale = width / float(NESVideoWidth);
    LOG(Info) << "Scale: " << m_screenScale << " set. Screen: " << int(NESVideoWidth * m_screenScale) << "x"
              << int(NESVideoHeight * m_screenScale) << std::endl;
}
void Emulator::setVideoScale(float scale)
{
    m_screenScale = scale;
    LOG(Info) << "Scale: " << m_screenScale << " set. Screen: " << int(NESVideoWidth * m_screenScale) << "x"
              << int(NESVideoHeight * m_screenScale) << std::endl;
}

void Emulator::setKeys(std::vector<sf::Keyboard::Key>& p1, std::vector<sf::Keyboard::Key>& p2)
{
    m_p1Keys = p1;
    m_p2Keys = p2;
}

void Emulator::muteAudio()
{
    m_audioPlayer.mute();
}

}
