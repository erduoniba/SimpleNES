//
//  ViewController.swift
//  HDSimpleNES
//
//  Owns the emulator session + all four host layers (video, audio, touch, MFi) and glues them
//  together for one screen's worth of gameplay. The whole stack shares a single UI thread — the
//  60 Hz CADisplayLink calls stepFrame() then triggers a Metal redraw, and audio pulls from the
//  APU queue on its own thread via NESAudioEngine. Input mutations happen on the UI thread and
//  are visible to the next stepFrame() call.
//

import UIKit
import MetalKit
import UniformTypeIdentifiers

class ViewController: UIViewController, UIDocumentPickerDelegate {

    // MARK: - Core

    private var session: EmulatorSession!
    private var audioEngine: NESAudioEngine!
    private var controllerBridge: GameControllerBridge!
    private var displayLink: CADisplayLink?

    // MARK: - Views

    private var metalView: MetalFramebufferView!
    private var gamepadView: TouchGamepadView!
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        l.text = "no ROM loaded — tap Open"
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "SimpleNES"

        // Emulator core — everything else assumes this exists.
        guard let s = EmulatorSession() else {
            statusLabel.text = "sn_emulator_create() failed"
            view.addSubview(statusLabel)
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return
        }
        session = s

        buildUI()
        wireInput()
        setupAudio()
        setupNavigationBar()
        autoloadDevROMIfPresent()
    }

    /// Dev-mode convenience: if the app's Documents dir has a ROM named `autoload.nes` (drop one
    /// there via Files.app / simctl / iTunes File Sharing), load it on launch. Skipping this in
    /// production is a one-line change; leaving it in makes iterating on the simulator painless
    /// because you don't have to tap through the picker every rebuild.
    private func autoloadDevROMIfPresent() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent("autoload.nes") else { return }
        // Also accept `tank.nes` as a common dev filename.
        var target = url
        if !FileManager.default.fileExists(atPath: target.path) {
            target = docs!.appendingPathComponent("tank.nes")
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return }

        if session.loadROM(path: target.path) {
            statusLabel.text = "autoloaded: \(target.lastPathComponent)"
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
    }

    // MARK: - UI

    private func buildUI() {
        // Metal framebuffer view — hardcoded to the NES resolution. Aspect ratio kept exact so
        // pixels don't smear; on portrait iPhone this leaves black bars at the top/bottom of the
        // video region above the gamepad.
        metalView = MetalFramebufferView(width: session.frameWidth, height: session.frameHeight)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferProvider = { [weak self] in
            self?.session.framebufferPointer
        }

        // Touch gamepad — sits at the bottom half, above the home indicator.
        gamepadView = TouchGamepadView()

        view.addSubview(metalView)
        view.addSubview(gamepadView)
        view.addSubview(statusLabel)

        let g = view.safeAreaLayoutGuide
        let aspect = CGFloat(session.frameWidth) / CGFloat(session.frameHeight)  // 256/240 ≈ 1.0667

        // Metal view wants to be as wide as possible (defaultHigh) but not exceed the safe-area
        // width, and not exceed 55% of the safe-area height once the aspect ratio is applied.
        // The equality constraints (aspect + top pin) plus ≤ caps give the layout engine enough to
        // pick a single winning size in every screen shape.
        let widthGrow = metalView.widthAnchor.constraint(equalTo: g.widthAnchor, constant: -16)
        widthGrow.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Video region — sits in the top half, letterboxed to NES aspect.
            metalView.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            metalView.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            widthGrow,
            metalView.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -16),
            metalView.widthAnchor.constraint(equalTo: metalView.heightAnchor, multiplier: aspect),
            // The vertical cap keeps the video from swallowing the gamepad on landscape iPads.
            metalView.heightAnchor.constraint(lessThanOrEqualTo: g.heightAnchor, multiplier: 0.55),

            // Status label — one line under the video.
            statusLabel.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 4),
            statusLabel.centerXAnchor.constraint(equalTo: g.centerXAnchor),

            // Gamepad — anchored to the bottom, full-width.
            gamepadView.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 4),
            gamepadView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            gamepadView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            gamepadView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            gamepadView.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Open",
            style: .plain,
            target: self,
            action: #selector(openROM)
        )
    }

    // MARK: - Input

    private func wireInput() {
        // Touch → session
        gamepadView.onButtonStateChanged = { [weak self] btn, pressed in
            self?.session.setButton(btn, pressed: pressed)
        }

        // MFi/Xbox/DualSense controller → session. Reuse the same button setter, so touch and
        // physical controller can both drive P1 simultaneously (physical button state simply
        // overrides touch's until the next event on that button).
        controllerBridge = GameControllerBridge()
        controllerBridge.onButtonStateChanged = { [weak self] btn, pressed in
            self?.session.setButton(btn, pressed: pressed)
        }
        controllerBridge.onConnectionChanged = { [weak self] connected in
            guard let self = self else { return }
            if connected, self.session.hasROM {
                self.statusLabel.text = "controller connected"
            }
        }
    }

    // MARK: - Audio

    private func setupAudio() {
        audioEngine = NESAudioEngine(session: session)
        audioEngine.start()
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        // Skip work until we have a ROM — the Metal view will keep presenting whatever texture
        // is already on the GPU (typically the last frame or black).
        if session.hasROM {
            session.stepFrame()
        }
        metalView.draw()
    }

    // MARK: - ROM picking

    @objc private func openROM() {
        // .nes isn't a system-known UTI, so we accept the broadest "any file" content type and
        // filter by data. UIDocumentPickerViewController shows Files.app + iCloud Drive.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // asCopy:true above means the file lives in the app's temp dir — no security-scoped
        // resource dance needed. Read straight into Data and pass to the core.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentLoadError(title: "Read failed", message: error.localizedDescription)
            return
        }

        NSLog("[HDSimpleNES] loading \(url.lastPathComponent) — \(data.count) bytes")
        let ok = session.loadROM(data: data)
        if ok {
            statusLabel.text = url.lastPathComponent
        } else {
            // sn_last_error() has the specific reason — surface it in a dialog so users know if
            // it's an unsupported mapper vs PAL vs truncated file vs not-a-NES-ROM. Text-status
            // alone reads as "the app is broken."
            let reason = session.lastError.isEmpty ? "unknown error" : session.lastError
            statusLabel.text = "load failed"
            presentLoadError(title: "Can't load \(url.lastPathComponent)", message: reason)
        }
    }

    /// One place for "picking a file blew up" error alerts. Keeps the UI feedback consistent
    /// across the read-failed and parse-failed paths.
    private func presentLoadError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
