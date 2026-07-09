#pragma once

#include <chrono>
#include <miniaudio.h>

#include "APU/spsc.hpp"

namespace sn
{

const std::chrono::milliseconds callback_period_ms { 120 };

struct CallbackData
{
    spsc::RingBuffer<float>& ring_buffer;
    ma_resampler*            resampler;
    std::vector<float>       input_frames_buffer;
    bool                     mute;
    int                      remaining_buffer_rounds;
};

// Receives input at a fixed sample rate from an externally-owned audio queue and uses miniaudio
// to resample and output to the audio device.
//
// The queue is now owned by CoreEmulator (the headless core) — AudioPlayer just holds a reference
// to it. This keeps the core free of any host audio dependency; the host can construct a different
// backend (AVAudioEngine on iOS, for example) that consumes the same queue.
//
// Why not SFML? SFML's SoundStream introduces additional buffers and has its own polling mechanism
// which introduces extra lag. Effectively using it would mean relying on its implementation-specific
// behaviour. Using miniaudio is simpler as we just need to implement one audio callback.
class AudioPlayer
{
public:
    const int output_sample_rate = ma_standard_sample_rate_44100;

    // The queue reference must outlive the AudioPlayer. In the desktop host this is arranged by
    // constructing AudioPlayer as a member declared AFTER the CoreEmulator that owns the queue.
    AudioPlayer(spsc::RingBuffer<float>& queue, int input_rate)
      : input_sample_rate(input_rate)
      , cb_data { queue, &resampler, {}, false, 1 }
    {
    }
    ~AudioPlayer();

    bool                    start();
    void                    mute();

    const int               input_sample_rate;

private:
    CallbackData     cb_data;

    bool             initialized = false;
    ma_device_config deviceConfig;
    ma_device        device;
    ma_resampler     resampler;
};
}
