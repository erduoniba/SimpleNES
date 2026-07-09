//
//  NESAudioEngine.swift
//  HDSimpleNES
//
//  AVAudioEngine host on top of the emulator's SPSC audio queue. The audio thread callback pulls
//  raw mono float samples from the queue (produced at ~894454 Hz) and downsamples them with
//  linear interpolation to the hardware sample rate (typically 44100 or 48000).
//
//  Why do the resampling here instead of letting AVAudioEngine handle it? Feeding AVAudioEngine
//  an AVAudioFormat at 894454 Hz gets rejected by CoreAudio on most devices — it's outside the
//  set of rates the mixer accepts. Simpler to run the source node at the hardware rate and
//  linear-interpolate ourselves. NES audio is ~1789 Hz-band chiptune anyway, so nearest-band
//  linear filtering is more than adequate.
//

import AVFoundation

final class NESAudioEngine {

    private let session: EmulatorSession
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // Pre-allocated pull buffer for the audio thread — never resized inside the render callback.
    private var pullBuffer: UnsafeMutablePointer<Float>
    private let pullCapacity: Int

    // Resampling cursor. Persists across callbacks so we don't lose fractional sample position
    // between blocks.
    private var srcPos: Double = 0

    // How many raw APU samples correspond to one output sample. Fixed at construction time from
    // the emulator's rates and the hardware sample rate.
    private let ratio: Double

    init(session: EmulatorSession) {
        self.session = session

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let outputRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 44_100.0
        self.ratio = Double(session.audioInputRate) / outputRate

        // Room for enough input samples to cover any callback size we're likely to see (< 4096
        // output frames on iOS), plus a safety margin.
        self.pullCapacity = 4096 * Int(ratio.rounded(.up)) + 16
        self.pullBuffer = UnsafeMutablePointer<Float>.allocate(capacity: pullCapacity)
        self.pullBuffer.initialize(repeating: 0, count: pullCapacity)

        // Mono float32 at the hardware output rate. AVAudioEngine will happily route this
        // straight through to the output node.
        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputRate,
            channels: 1,
            interleaved: false
        )!

        let node = AVAudioSourceNode(format: renderFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.render(frameCount: Int(frameCount), abl: audioBufferList)
        }
        self.sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
    }

    deinit {
        pullBuffer.deallocate()
    }

    func start() {
        // .ambient respects the silent switch and mixes with other apps — reasonable default for
        // a game. If we ever want silent-switch override, upgrade to .playback here.
        do {
            let ax = AVAudioSession.sharedInstance()
            try ax.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try ax.setActive(true)
        } catch {
            NSLog("[HDSimpleNES] AVAudioSession setup failed: %@", error.localizedDescription)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[HDSimpleNES] AVAudioEngine start failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Render (audio thread — do not allocate, do not lock)

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let dataPtr = buffers[0].mData else { return noErr }
        let out = dataPtr.assumingMemoryBound(to: Float.self)

        // Pull enough input to feed `frameCount` output samples plus one extra for the trailing
        // linear-interp lerp.
        let needed = Int(Double(frameCount) * ratio + srcPos) + 2
        let capped = min(needed, pullCapacity)

        let got = session.pullAudio(into: pullBuffer, maxSamples: capped)

        if got == 0 {
            // Emulator is silent (no ROM yet, or paused). Emit zeros.
            for i in 0..<frameCount { out[i] = 0 }
            srcPos = 0
            return noErr
        }

        // Extend the buffer with the last real sample so tail lerp doesn't reach into stale data.
        if got < capped {
            let last = pullBuffer[got - 1]
            for i in got..<capped { pullBuffer[i] = last }
        }

        var pos = srcPos
        let lastValidIdx = capped - 1
        for i in 0..<frameCount {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let iA = min(idx, lastValidIdx)
            let iB = min(idx + 1, lastValidIdx)
            let a = pullBuffer[iA]
            let b = pullBuffer[iB]
            out[i] = a + (b - a) * frac
            pos += ratio
        }
        // Carry the fractional position across callbacks so the wave stays continuous.
        srcPos = pos - Double(Int(pos))

        return noErr
    }
}
