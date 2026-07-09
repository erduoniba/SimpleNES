//
//  GameControllerBridge.swift
//  HDSimpleNES
//
//  Observes GameController.framework and forwards MFi / Xbox / DualSense button/D-pad state to
//  the emulator. NES has 8 buttons total (D-pad + A + B + Select + Start) — everything else on
//  a modern controller (triggers, second stick, shoulder buttons) is ignored.
//

import GameController

final class GameControllerBridge {

    var onButtonStateChanged: ((NESButton, Bool) -> Void)?

    /// Called when the user connects/disconnects a controller, so the UI can hint at MFi support.
    var onConnectionChanged: ((Bool) -> Void)?

    private var currentController: GCController?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init() {
        let nc = NotificationCenter.default
        connectObserver = nc.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, let c = note.object as? GCController else { return }
            self.attach(c)
        }
        disconnectObserver = nc.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, let c = note.object as? GCController else { return }
            if self.currentController === c { self.detach() }
        }

        // Some controllers are already connected at launch.
        if let already = GCController.controllers().first {
            attach(already)
        }
    }

    deinit {
        if let o = connectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = disconnectObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func attach(_ c: GCController) {
        currentController = c
        onConnectionChanged?(true)

        // extendedGamepad covers 99% of controllers connected to iOS these days (Xbox, DualSense,
        // Xbox Series, Backbone, etc.). microGamepad is Siri Remote only — not worth supporting.
        guard let gp = c.extendedGamepad else { return }

        gp.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.a, pressed)
        }
        gp.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.b, pressed)
        }
        // menu ≙ Start, options ≙ Select — the pattern most retro emulators settle on.
        gp.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.start, pressed)
        }
        gp.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.select, pressed)
        }

        // D-pad — each direction fires independently. The GC framework already deals with the
        // "both up and down pressed" corner cases (which real controllers can generate briefly
        // during rocking), so no debouncing here.
        gp.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.up, pressed)
        }
        gp.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.down, pressed)
        }
        gp.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.left, pressed)
        }
        gp.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.onButtonStateChanged?(.right, pressed)
        }

        // Left analog stick — treat as 4-directional with a 40% deadzone. Beyond that threshold
        // we drive the same NES button as the D-pad. This is how most emulators handle it.
        gp.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self = self else { return }
            let dz: Float = 0.4
            self.onButtonStateChanged?(.up,    y >  dz)
            self.onButtonStateChanged?(.down,  y < -dz)
            self.onButtonStateChanged?(.left,  x < -dz)
            self.onButtonStateChanged?(.right, x >  dz)
        }
    }

    private func detach() {
        currentController = nil
        onConnectionChanged?(false)
    }
}
