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
//  This VC is the app's root — it's what SceneDelegate wraps in a UINavigationController and
//  hands to the window. The game library lives as a MODAL SHEET that the user opens via the
//  right-hand nav-bar button; when they pick a row there we swap ROMs in-place (see
//  `loadROMData(_:statusName:)`) and dismiss the sheet.
//
//  ROM lifecycle:
//   - Initial: SceneDelegate can preload `preloadedROMData` before the VC gets its window (used
//     to restore the last-played game on cold launch, via `Prefs.lastPlayedHash`).
//   - Runtime switch: LibraryViewController.onSelectROM → loadROMData(...) with the new bytes.
//     We snapshot the current SRAM before swapping, then load + restore the new game's save.
//   - Empty start: if no preloaded ROM AND the library is empty on first launch, we auto-
//     present the library sheet so the user has somewhere to go — otherwise they'd stare at
//     a black metal view.
//

import UIKit
import MetalKit
import UniformTypeIdentifiers

class ViewController: UIViewController {

    // MARK: - Preloaded ROM (set by SceneDelegate before window shows)

    /// ROM bytes to load in viewDidLoad. Set by SceneDelegate when restoring the last-played
    /// game on cold launch. If nil, the library sheet auto-opens (see `viewDidAppear`) so the
    /// user has somewhere to go instead of staring at a black metal view.
    var preloadedROMData: Data?
    /// Display name shown in the status label + nav-bar title. Same string the library shows.
    var preloadedROMTitle: String?

    // MARK: - Core

    private var session: EmulatorSession!
    private var audioEngine: NESAudioEngine!
    private var controllerBridge: GameControllerBridge!
    private var displayLink: CADisplayLink?
    /// Battery-backed cartridge RAM store. Persists per-ROM save files under Documents/saves/.
    /// Saves fire on background (didEnterBackground), reset (before session.reset), and app
    /// termination (willTerminate). Loads fire immediately after `session.loadROM`.
    private let sramStore = SRAMStore()
    /// Tap-to-pause state: user tapped the game area to freeze the frame. Distinct from the
    /// background-triggered pause in `appDidEnterBackground` — this one survives foreground
    /// returns (locking the phone while paused stays paused after unlock).
    private var isPausedByUser = false
    // MARK: - Views

    private var metalView: MetalFramebufferView!
    private var gamepadView: TouchGamepadView!
    /// Semi-transparent overlay shown over the frozen game frame when paused. Centered play icon
    /// on a dark round pill so the user immediately reads "tap to resume." Not part of the touch
    /// gamepad — it's a purely visual affordance; taps pass through to the metalView's tap
    /// recognizer via `isUserInteractionEnabled = false`.
    private let pauseOverlay: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        container.isHidden = true
        container.isUserInteractionEnabled = false

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badge.layer.cornerRadius = 36
        container.addSubview(badge)

        let icon = UIImageView(image: UIImage(systemName: "play.fill"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        badge.addSubview(icon)

        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            // Nudge the triangle a hair to the right — play.fill's optical center sits left of
            // its bounding box, so a naive centerX makes it look off-center to the eye.
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])
        return container
    }()
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        l.text = "loading…"
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "SimpleHappy"

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
        observeAppLifecycle()

        // Apply the saved theme (or the default) — must come AFTER buildUI so `gamepadView` and
        // `backgroundGradientLayer` exist. Persisted in UserDefaults via Prefs; first-launch
        // users get `GamepadTheme.all[0]` (classic gray).
        let themeID = Prefs.selectedTheme ?? GamepadTheme.all[0].id
        applyTheme(GamepadTheme.theme(for: themeID))

        // Load whatever the library pushed us with. Nothing to fall back on — the library is now
        // the only ROM source, so a nil preloadedROMData means we were pushed empty (shouldn't
        // happen in the normal flow, but we handle it gracefully by showing the empty state).
        if let data = preloadedROMData {
            loadROMData(data, statusName: preloadedROMTitle ?? "ROM")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - App lifecycle

    /// When the app backgrounds (home button, app switcher, incoming call banner accepted, screen
    /// lock) we need to (a) stop the CADisplayLink so we don't waste CPU/battery pretending to
    /// render off-screen, and (b) pause the audio engine so iOS doesn't kill our audio session for
    /// misbehaving. Coming back from background, we do the reverse.
    ///
    /// This is the iOS analog of the desktop `Emulator.cpp` window-focus pause — same idea, just
    /// with UIKit notifications instead of SFML events.
    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        // willTerminate isn't guaranteed to fire (iOS kills apps silently when memory is tight or
        // the user force-quits from the app switcher) but when it *does* fire we get one last
        // window to flush SRAM. Cheap belt-and-suspenders on top of didEnterBackground, which is
        // the primary save trigger.
        nc.addObserver(self, selector: #selector(appWillTerminate),
                       name: UIApplication.willTerminateNotification, object: nil)
    }

    @objc private func appDidEnterBackground() {
        // Flush SRAM before pausing anything else — background is the primary save trigger. iOS
        // may kill the process at any time after this notification (typically 5s later); we
        // want the save on disk BEFORE we start tearing down the display link and audio engine.
        sramStore.saveFromSession(session)
        stopDisplayLink()
        audioEngine?.pause()
    }

    @objc private func appWillEnterForeground() {
        // viewDidAppear also fires on foreground return, but only if the VC is on screen. Being
        // explicit here means we're correct even if the VC is presented modally or covered.
        startDisplayLink()
        // Only auto-resume audio if the user hadn't manually paused before backgrounding —
        // otherwise unlocking the phone would silently undo their tap-pause.
        if !isPausedByUser {
            audioEngine?.resume()
        }
    }

    @objc private func appWillTerminate() {
        // Last-chance save. May not fire (see observeAppLifecycle) so this is not the primary
        // save path — didEnterBackground is. Kept for the case where the user force-quits from
        // the app switcher while the VC is on screen but the app never actually backgrounded
        // (e.g. background transition was skipped by iOS).
        sramStore.saveFromSession(session)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()

        // If we came up without a ROM AND haven't nudged the user yet this session, pop the
        // library sheet — a black metal view with no context reads as "the app is broken."
        // Guarded by `didAutoPresentLibrary` so we don't re-open every time the sheet closes.
        // (The user picking a ROM and closing the sheet counts as "you've seen it," even if
        // they didn't actually start a game — no more auto-opens this session.)
        if session?.hasROM == false && !didAutoPresentLibrary && presentedViewController == nil {
            didAutoPresentLibrary = true
            openLibrary()
        }
    }

    /// One-shot guard for the auto-present-on-empty behavior. Set once per VC lifetime; the
    /// user opening the sheet manually doesn't touch this — only the automatic path.
    private var didAutoPresentLibrary = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
    }

    // MARK: - UI

    // Portrait: video on top, gamepad on the bottom half (classic split layout).
    // Landscape: video fills the safe area (aspect-fit), gamepad OVERLAYS the whole area with
    // transparent background — the D-pad and A/B buttons naturally land in the letterbox strips
    // on the left/right of the video. Same pattern Delta/Provenance/RetroArch use for phones,
    // because on landscape phones there's no vertical room to stack anything below the picture.
    //
    // Two mutually-exclusive constraint sets, swapped in `applyLayoutForCurrentSize()` when
    // orientation changes (via viewWillTransition or trait change).
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []

    private func buildUI() {
        // Metal framebuffer view — hardcoded to the NES resolution. Aspect ratio kept exact so
        // pixels don't smear.
        metalView = MetalFramebufferView(width: session.frameWidth, height: session.frameHeight)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferProvider = { [weak self] in
            self?.session.framebufferPointer
        }

        // Touch gamepad — clear background; only the button shapes draw. In landscape it overlays
        // the whole safe area, so the transparent gaps between buttons let the game show through.
        gamepadView = TouchGamepadView()
        gamepadView.backgroundColor = .clear

        view.addSubview(metalView)
        view.addSubview(gamepadView)
        view.addSubview(statusLabel)

        // Pause overlay pinned to metalView — scales with the picture in both orientations and
        // never obscures the touch gamepad. Behind the tap gesture; taps pass through.
        metalView.addSubview(pauseOverlay)
        NSLayoutConstraint.activate([
            pauseOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            pauseOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            pauseOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            pauseOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
        ])

        let g = view.safeAreaLayoutGuide
        let aspect = CGFloat(session.frameWidth) / CGFloat(session.frameHeight)  // 256/240 ≈ 1.0667

        // Universal constraint — aspect ratio is always locked, orientation-independent.
        metalView.widthAnchor.constraint(equalTo: metalView.heightAnchor, multiplier: aspect).isActive = true

        // ---------- Portrait: metalView on top, gamepad fills the bottom slab ----------
        let portraitWidthGrow = metalView.widthAnchor.constraint(equalTo: g.widthAnchor, constant: -16)
        portraitWidthGrow.priority = .defaultHigh

        portraitConstraints = [
            metalView.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            metalView.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            portraitWidthGrow,
            metalView.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor, constant: -16),
            // The height cap in portrait leaves room for the gamepad below — 55% is picked so
            // the touch controls get a comfortable ~260pt strip on every iPhone size class.
            metalView.heightAnchor.constraint(lessThanOrEqualTo: g.heightAnchor, multiplier: 0.55),

            statusLabel.topAnchor.constraint(equalTo: metalView.bottomAnchor, constant: 4),
            statusLabel.centerXAnchor.constraint(equalTo: g.centerXAnchor),

            gamepadView.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 4),
            gamepadView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            gamepadView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            gamepadView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            gamepadView.heightAnchor.constraint(equalToConstant: 260),
        ]

        // ---------- Landscape: metalView fills, gamepad overlays entire safe area ----------
        // Video: aspect-fit inside the safe area. `<= width` and `<= height` bound both sides;
        // an `equalTo width, priority=high` + `equalTo height, priority=high` fight it out and
        // the one that keeps aspect (via the always-on aspect constraint) wins. Result: the
        // largest rectangle of correct aspect that fits, centered.
        let landscapeWidthGrow = metalView.widthAnchor.constraint(equalTo: g.widthAnchor)
        landscapeWidthGrow.priority = .defaultHigh
        let landscapeHeightGrow = metalView.heightAnchor.constraint(equalTo: g.heightAnchor)
        landscapeHeightGrow.priority = .defaultHigh

        landscapeConstraints = [
            metalView.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            metalView.centerYAnchor.constraint(equalTo: g.centerYAnchor),
            landscapeWidthGrow,
            landscapeHeightGrow,
            metalView.widthAnchor.constraint(lessThanOrEqualTo: g.widthAnchor),
            metalView.heightAnchor.constraint(lessThanOrEqualTo: g.heightAnchor),

            // Gamepad covers the whole safe area. Its own subviews (D-pad, A/B, Start/Select) are
            // anchored to their edges + centerY, so they land in the letterbox strips flanking
            // the video. Anywhere the gamepad is transparent, the game view underneath shows
            // through — including through the middle of the picture, which is fine because no
            // touch targets live there.
            gamepadView.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            gamepadView.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            gamepadView.topAnchor.constraint(equalTo: g.topAnchor),
            gamepadView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
        ]

        applyLayoutForCurrentSize()

        // Tap the game picture to pause/resume. Attached to metalView (not the whole view) so
        // taps on the touch gamepad still reach the buttons — in landscape the gamepad overlays
        // the picture and its buttons hit-test first, so only taps landing on the transparent
        // gaps between buttons will toggle pause. That's the intended feel.
        metalView.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleGameAreaTap))
        metalView.addGestureRecognizer(tap)
    }

    /// Which constraint set is currently installed. Nil until first apply.
    private var isLandscapeLayout: Bool?

    /// Pick portrait vs landscape by aspect ratio of the view. Called on first layout and on every
    /// size transition. Idempotent — if the correct set is already installed we don't touch it.
    private func applyLayoutForCurrentSize() {
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return }
        let wantsLandscape = view.bounds.width > view.bounds.height
        if isLandscapeLayout == wantsLandscape { return }
        isLandscapeLayout = wantsLandscape

        if wantsLandscape {
            NSLayoutConstraint.deactivate(portraitConstraints)
            NSLayoutConstraint.activate(landscapeConstraints)
            // Status label would sit awkwardly in the middle of the picture in landscape — the
            // nav bar's `title` already shows the ROM name. Hide the label to reclaim clarity.
            statusLabel.isHidden = true
        } else {
            NSLayoutConstraint.deactivate(landscapeConstraints)
            NSLayoutConstraint.activate(portraitConstraints)
            statusLabel.isHidden = false
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Swap constraint sets INSIDE the coordinator's animation block so the rotation animates
        // smoothly instead of snapping. `size` is the post-rotation size, so we consult it
        // directly instead of `view.bounds` (which is still the pre-rotation value here).
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            let wantsLandscape = size.width > size.height
            if self.isLandscapeLayout != wantsLandscape {
                self.isLandscapeLayout = wantsLandscape
                if wantsLandscape {
                    NSLayoutConstraint.deactivate(self.portraitConstraints)
                    NSLayoutConstraint.activate(self.landscapeConstraints)
                    self.statusLabel.isHidden = true
                } else {
                    NSLayoutConstraint.deactivate(self.landscapeConstraints)
                    NSLayoutConstraint.activate(self.portraitConstraints)
                    self.statusLabel.isHidden = false
                }
                self.view.layoutIfNeeded()
            }
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Catches the initial layout (viewWillTransition doesn't fire for the first appearance)
        // and any window-size shift on iPad multitasking. Cheap when there's nothing to do —
        // `applyLayoutForCurrentSize` early-returns if the current set is correct.
        applyLayoutForCurrentSize()
    }

    private func setupNavigationBar() {
        // Left: Library — the app's only ROM entry point. We're the root VC; the list is a sheet
        // we own and dismiss.
        let libraryItem = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            style: .plain,
            target: self,
            action: #selector(openLibrary)
        )
        libraryItem.accessibilityLabel = "游戏列表"
        navigationItem.leftBarButtonItem = libraryItem

        // Right: Settings — theme selection and future preferences live behind this gear. Kept
        // as the only right-hand item on purpose: fewer taps to misfire during gameplay.
        let settingsItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        settingsItem.accessibilityLabel = "设置"
        navigationItem.rightBarButtonItem = settingsItem
    }

    // MARK: - Settings sheet

    /// Present the settings screen as a `.pageSheet` modal. Currently the only setting is theme
    /// selection, but the sheet is set up as a `UITableViewController` so adding rows (sound
    /// toggle, controller mapping, ...) later is one section append rather than a rewrite.
    @objc private func openSettings() {
        let settings = SettingsViewController(style: .insetGrouped)
        settings.onThemeChanged = { [weak self] theme in
            self?.applyTheme(theme)
        }
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    // MARK: - Theme

    /// Install the given theme on the on-screen gamepad — colors AND visual style (raised, neon,
    /// pixel, glass, flat). Persists the choice via `Prefs.setSelectedTheme` so it survives
    /// across launches. Background stays system default — themes only skin the buttons.
    ///
    /// Safe to call mid-game — the emulator core doesn't know or care. Metal view is untouched.
    fileprivate func applyTheme(_ theme: GamepadTheme) {
        gamepadView.applyTheme(theme)
        Prefs.setSelectedTheme(theme.id)
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

    // MARK: - Library sheet

    /// Present the game list as a `.pageSheet` modal. Swipe-down works to dismiss, but the
    /// sheet also has its own Close button. Selecting a ROM inside the sheet fires
    /// `onSelectROM`, which we route through `loadROMData(_:statusName:)` to swap the emulator
    /// in place — same code path used by SceneDelegate on cold launch.
    @objc private func openLibrary() {
        let library = LibraryViewController(style: .plain)
        library.onSelectROM = { [weak self] entry, data in
            // Sheet dismisses itself before calling us back — swap happens under the dismiss
            // animation and by the time the player is visible the new game is already running.
            self?.loadROMData(data, statusName: entry.displayName)
            Prefs.setLastPlayedHash(entry.hash)
        }
        let nav = UINavigationController(rootViewController: library)
        // `.pageSheet` is the modern iOS sheet — leaves a strip of the player VC visible at top,
        // grab handle at top of the sheet, drag-down to dismiss. Not `.formSheet` (iPad-centric)
        // or `.fullScreen` (heavier than the situation calls for).
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.selectedDetentIdentifier = .large
        }
        present(nav, animated: true)
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
        // is already on the GPU (typically the last frame or black). Also skip while the user
        // has tapped the game area to pause; the last frame stays on screen.
        if session.hasROM && !isPausedByUser {
            session.stepFrame()
        }
        metalView.draw()
    }

    // MARK: - Tap-to-pause

    /// Tap anywhere on the game picture to toggle pause/resume. Only registered on `metalView`
    /// so taps on the gamepad area still go to the touch controls (in landscape the gamepad
    /// overlays the picture — this handler sits BEHIND it, so button touches win via the normal
    /// hit-test order and only taps on the transparent gaps toggle pause).
    @objc private func handleGameAreaTap() {
        guard session.hasROM else { return }
        isPausedByUser.toggle()
        if isPausedByUser {
            audioEngine?.pause()
            statusLabel.text = "paused — 点击画面继续"
            showPauseOverlay(true)
        } else {
            audioEngine?.resume()
            statusLabel.text = title ?? "running"
            showPauseOverlay(false)
        }
    }

    /// Fade the play-icon overlay in/out. Kept short (0.15s) so it feels like a status indicator,
    /// not a scene transition.
    private func showPauseOverlay(_ show: Bool) {
        if show {
            pauseOverlay.alpha = 0
            pauseOverlay.isHidden = false
            UIView.animate(withDuration: 0.15) { [weak self] in
                self?.pauseOverlay.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.15, animations: { [weak self] in
                self?.pauseOverlay.alpha = 0
            }, completion: { [weak self] _ in
                self?.pauseOverlay.isHidden = true
            })
        }
    }

    // MARK: - ROM loading

    /// Load a ROM from raw Data, wiring SRAM save-then-hash-then-load-then-restore in the right
    /// order. Returns true on success (status label already updated), false on failure (status
    /// label + error alert both shown here).
    ///
    /// Called from three places: viewDidLoad on cold-launch preload, the library sheet's
    /// onSelectROM callback for runtime ROM switches, and (currently unused) any future
    /// keyboard shortcut. Safe to call while a ROM is already running — the current game's
    /// SRAM is flushed before the swap.
    @discardableResult
    func loadROMData(_ data: Data, statusName: String) -> Bool {
        // Save whatever was in memory for the *previous* ROM before we blow it away. If the load
        // below fails we've still preserved the old game's progress. If it succeeds the new
        // ROM's save (if any) gets restored on top.
        if session.hasROM {
            sramStore.saveFromSession(session)
        }

        // Hash the new ROM BEFORE calling loadROM — sramStore uses this hash to pick a save
        // file, and we need it in place before the immediately-following restore.
        sramStore.rememberROM(data: data)

        let ok = session.loadROM(data: data)
        if ok {
            // loadROM internally calls reset(), which now has a fresh mapper with zeroed SRAM.
            // Restore any persisted bytes on top.
            sramStore.loadSaveIntoSession(session)
            statusLabel.text = statusName
            title = statusName
            // Snap out of tap-pause on ROM swap — otherwise the user picks a new game from the
            // library and it silently loads paused, which reads as "the app is broken."
            isPausedByUser = false
            showPauseOverlay(false)
            audioEngine?.resume()
            return true
        } else {
            // Don't leave a dangling hash — if the user goes back to the list and picks another
            // ROM that DOES load, we'd otherwise save its SRAM under the failed ROM's hash.
            sramStore.clearRomHash()
            statusLabel.text = "load failed"
            let reason = session.lastError.isEmpty ? "unknown error" : session.lastError
            let alert = UIAlertController(
                title: "Can't load \(statusName)",
                message: reason,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return false
        }
    }
}
