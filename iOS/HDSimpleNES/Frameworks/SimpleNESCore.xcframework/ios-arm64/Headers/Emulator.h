#ifndef EMULATOR_H
#define EMULATOR_H
#include <SFML/Graphics.hpp>
#include <SFML/Window.hpp>
#include <chrono>
#include <string>
#include <vector>

#include "AudioPlayer.h"
#include "CoreEmulator.h"

namespace sn
{
using TimePoint          = std::chrono::high_resolution_clock::time_point;
using Duration           = std::chrono::high_resolution_clock::duration;

const int NESVideoWidth  = ScanlineVisibleDots;
const int NESVideoHeight = VisibleScanlines;

// SFML-based desktop host on top of CoreEmulator. Owns the window, the audio playback backend
// (miniaudio via AudioPlayer), and the SFML event loop. The core is fully headless.
class Emulator
{
public:
    Emulator();
    void run(std::string rom_path);
    void setVideoWidth(int width);
    void setVideoHeight(int height);
    void setVideoScale(float scale);
    void setKeys(std::vector<sf::Keyboard::Key>& p1, std::vector<sf::Keyboard::Key>& p2);
    void muteAudio();

private:
    // Sample the SFML keyboard state into both controllers of the core. Called once per rendered frame.
    void            pollInput();

    CoreEmulator    m_core;
    // AudioPlayer consumes the core's SPSC queue on the audio thread. It's constructed AFTER
    // m_core because it holds a reference to m_core.audioQueue().
    AudioPlayer     m_audioPlayer;

    sf::RenderWindow m_window;
    sf::Texture      m_frameTexture;   // 256x240 RGBA, updated from the core's screen every frame
    sf::Sprite       m_frameSprite;    // wraps m_frameTexture and is scaled to the window size
    float            m_screenScale;

    // Key bindings pushed into m_core.controller(0/1) each frame from pollInput().
    std::vector<sf::Keyboard::Key> m_p1Keys;
    std::vector<sf::Keyboard::Key> m_p2Keys;

    TimePoint m_lastWakeup;
    Duration  m_elapsedTime;
};
}
#endif // EMULATOR_H
