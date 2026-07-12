//
//  NESAudioEngine.swift
//  HDSimpleHappy
//
//  AVAudioEngine host on top of the emulator's SPSC audio queue. The audio thread callback pulls
//  raw mono float samples from the queue (produced at ~894454 Hz), runs them through a two-stage
//  1-pole IIR chain (~90 Hz high-pass to remove APU DC bias, ~14 kHz low-pass to kill aliasing),
//  then linear-interpolates down to the hardware sample rate (typically 44100 or 48000).
//
//  Why do the resampling here instead of letting AVAudioEngine handle it? Feeding AVAudioEngine
//  an AVAudioFormat at 894454 Hz gets rejected by CoreAudio on most devices — it's outside the
//  set of rates the mixer accepts. Simpler to run the source node at the hardware rate and
//  linear-interpolate ourselves.
//
//  Why the pre-decimation IIR filters? The raw APU mixer output contains pulse-channel harmonics
//  all the way up to input-Nyquist (~447 kHz). Naïve 20:1 decimation to 44100 Hz folds those into
//  the audible band as piercing high-frequency noise — the classic "shrieking emulator" symptom.
//  The 14 kHz LP kills them before they can alias. Separately, the raw mixer output has a large
//  DC bias (all samples ≥ 0, mean ≈ 0.26 during gameplay); the 90 Hz HP removes it so silence is
//  actually silence and we don't waste speaker headroom on a constant offset.
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

    // Anti-alias / DC-block filter state. NES emulators universally apply two 1-pole IIR filters
    // before downsampling:
    //   - High-pass @ ~90 Hz removes the APU's built-in DC bias (raw mixer output is all-positive,
    //     mean ≈ 0.26). Without this, silence is a constant non-zero level, we waste headroom, and
    //     start/stop pops.
    //   - Low-pass @ ~14 kHz kills the pulse-channel harmonics that live between the audible band
    //     and our input Nyquist (~447 kHz). Naïve linear-interp decimation folds those back down as
    //     piercing high-frequency noise — this is what "the game emits a shrieking sound" was.
    //
    // Coefficients derived from time-constant formulas at the input rate (894454 Hz). Recomputed
    // on init from `session.audioInputRate` so they follow whatever the core reports.
    private let hpAlpha: Float        // high-pass — closer to 1.0 = lower cutoff
    private let lpAlpha: Float        // low-pass — smaller = lower cutoff
    private var hpPrevIn: Float  = 0  // last input sample
    private var hpPrevOut: Float = 0  // last hp output
    private var lpPrevOut: Float = 0  // last lp output

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

        // 1-pole IIR coefficients at the APU input rate. Standard formulas:
        //   HP:  y[n] = a*(y[n-1] + x[n] - x[n-1]),  a = τ / (τ + dt)  where τ = 1/(2π·fc)
        //   LP:  y[n] = y[n-1] + α*(x[n] - y[n-1]), α = dt / (τ + dt)
        // fc_hp = 90 Hz (kill DC), fc_lp = 14 kHz (kill aliasing before decimation).
        let inputRate = Double(session.audioInputRate)
        let dt = 1.0 / inputRate
        let tauHP = 1.0 / (2.0 * .pi * 90.0)
        let tauLP = 1.0 / (2.0 * .pi * 14_000.0)
        self.hpAlpha = Float(tauHP / (tauHP + dt))
        self.lpAlpha = Float(dt / (tauLP + dt))

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
        NotificationCenter.default.removeObserver(self)
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
            NSLog("[HDSimpleHappy] AVAudioSession setup failed: %@", error.localizedDescription)
        }

        // Register once — start()/pause()/resume() may fire many times, but observation is stable
        // for the lifetime of this engine. Remove is idempotent so this is safe on re-entry.
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        nc.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        nc.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )

        startEngineIfNeeded()
    }

    func stop() {
        engine.stop()
    }

    /// Lightweight pause — used when the app backgrounds. Doesn't tear down the graph; a matching
    /// `resume()` restarts audio production immediately without reallocating buffers.
    func pause() {
        if engine.isRunning {
            engine.pause()
        }
    }

    /// Counterpart to `pause()`. Reactivates the audio session (in case iOS deactivated it while
    /// backgrounded) and restarts the engine. Safe to call when already running.
    func resume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[HDSimpleHappy] AVAudioSession reactivate failed: %@", error.localizedDescription)
        }
        startEngineIfNeeded()
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[HDSimpleHappy] AVAudioEngine start failed: %@", error.localizedDescription)
        }
    }

    // MARK: - AVAudioSession notifications

    /// Handles phone calls, Siri, another app grabbing exclusive audio, etc.
    /// On `.began` iOS has already stopped the engine for us; we just note the state. On `.ended`
    /// we look at `.shouldResume` — if the interruption source politely said we can resume, we
    /// reactivate and restart. Otherwise we stay silent until the user comes back to the app,
    /// which triggers `willEnterForegroundNotification` → `resume()` in ViewController.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // iOS 已经停了 engine，这里主要是保持状态一致。
            if engine.isRunning { engine.pause() }
        case .ended:
            let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            if opts.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    /// Handles headphone unplug and similar route changes. When headphones are yanked, the polite
    /// behavior for a game is to pause — otherwise the game blasts out the built-in speaker in a
    /// meeting/library. `.ambient` category still respects the silent switch, but that's separate
    /// from route change.
    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        if reason == .oldDeviceUnavailable {
            // Headphones (or bluetooth device) went away. Pause audio; the user can resume
            // playback deliberately by returning to the app / interacting.
            pause()
        }
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

        // Filter chain at input rate — DC block (HP ~90 Hz) then anti-alias (LP ~14 kHz).
        // MUST run at input rate BEFORE decimation, or the aliasing has already happened and no
        // downstream filter can un-fold it. This is the fix for the piercing high-frequency
        // shriek that came from naïve 20:1 linear-interp decimation of pulse-wave harmonics.
        var hpIn  = hpPrevIn
        var hpOut = hpPrevOut
        var lpOut = lpPrevOut
        let ha = hpAlpha
        let la = lpAlpha
        for i in 0..<got {
            let x = pullBuffer[i]
            hpOut = ha * (hpOut + x - hpIn)   // 1-pole high-pass
            hpIn  = x
            lpOut = lpOut + la * (hpOut - lpOut)  // 1-pole low-pass
            pullBuffer[i] = lpOut
        }
        hpPrevIn  = hpIn
        hpPrevOut = hpOut
        lpPrevOut = lpOut

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
