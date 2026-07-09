#pragma once

#include "APU/DMC.h"
#include "APU/FrameCounter.h"
#include "APU/Noise.h"
#include "APU/Pulse.h"
#include "APU/Timer.h"
#include "APU/Triangle.h"
#include "APU/spsc.hpp"
#include "IRQ.h"

namespace sn
{
class APU
{
public:
    Pulse        pulse1 { Pulse::Type::Pulse1 };
    Pulse        pulse2 { Pulse::Type::Pulse2 };
    Triangle     triangle;
    Noise        noise;
    DMC          dmc;

    FrameCounter frame_counter;

public:
    // APU pushes mixed samples into `queue` at CPU-clock frequency (downsampled by sampling_timer
    // to `output_sample_rate` Hz). The queue reference must outlive this APU instance and be
    // consumed by a single reader thread (the audio backend) — matches the SPSC contract.
    APU(spsc::RingBuffer<float>& queue, int output_sample_rate, IRQHandle& irq,
        std::function<Byte(Address)> dmcDma)
      : dmc(irq, dmcDma)
      , frame_counter(setup_frame_counter(irq))
      , audio_queue(queue)
      , sampling_timer(nanoseconds(int64_t(1e9) / int64_t(output_sample_rate)))
    {
    }

    // clock at the same frequency as the cpu
    void step();

    void writeRegister(Address addr, Byte value);
    Byte readStatus();

private:
    FrameCounter             setup_frame_counter(IRQHandle& irq);
    bool                     divideByTwo = false;

    spsc::RingBuffer<float>& audio_queue;
    Timer                    sampling_timer;
};

}
