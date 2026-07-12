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
    /// User-initiated pause via the toolbar button. Distinct from app-backgrounding pause — this
    /// one persists until the user hits the button again, even after foreground/background cycles.
    private var isPausedByUser = false
    private var pauseButton: UIBarButtonItem?

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
        l.text = "loading…"
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
        // Honor the user-pause state — if the user paused before backgrounding, keep the game
        // paused. Otherwise they hit "pause", locked the phone, unlocked, and their pause got
        // silently undone. Only auto-resume audio when we weren't user-paused.
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
        // Right side: Library (rightmost, primary escape hatch) + Pause + Theme picker. The
        // library button is this VC's ONLY entry into the game list — no back button, no push,
        // no separate root. We're the app's root; the list is a sheet we own and dismiss.
        let libraryItem = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            style: .plain,
            target: self,
            action: #selector(openLibrary)
        )
        libraryItem.accessibilityLabel = "游戏列表"

        let pauseItem = UIBarButtonItem(
            image: UIImage(systemName: "pause.fill"),
            style: .plain,
            target: self,
            action: #selector(togglePause)
        )
        pauseItem.accessibilityLabel = "Pause"
        self.pauseButton = pauseItem

        // Theme picker — palette icon (paintpalette.fill) opens an action sheet listing every
        // theme in the catalog with a checkmark on the current one. Kept in the right group so
        // both "game-controls" style items live on the same side.
        let themeItem = UIBarButtonItem(
            image: UIImage(systemName: "paintpalette.fill"),
            style: .plain,
            target: self,
            action: #selector(openThemePicker)
        )
        themeItem.accessibilityLabel = "外观"

        // Rightmost first in the array — so order on screen (right-to-left): library, pause, theme.
        navigationItem.rightBarButtonItems = [libraryItem, pauseItem, themeItem]

        // Left side: Reset — behind a UIAlertController confirmation so a fat-finger tap doesn't
        // nuke a run in progress.
        let resetItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.counterclockwise"),
            style: .plain,
            target: self,
            action: #selector(resetROM)
        )
        resetItem.accessibilityLabel = "Reset"
        navigationItem.leftBarButtonItem = resetItem
    }

    // MARK: - Theme

    /// Install the given theme on the on-screen gamepad — colors AND visual style (raised, neon,
    /// pixel, glass, flat). Persists the choice via `Prefs.setSelectedTheme` so it survives
    /// across launches. Background stays system default — themes only skin the buttons.
    ///
    /// Safe to call mid-game — the emulator core doesn't know or care. Metal view is untouched.
    private func applyTheme(_ theme: GamepadTheme) {
        gamepadView.applyTheme(theme)
        Prefs.setSelectedTheme(theme.id)
    }

    /// Action-sheet picker. Lists every theme in `GamepadTheme.all` with a checkmark on the
    /// currently selected one (looked up from Prefs — same source-of-truth as cold launch).
    /// Uses `.actionSheet` on iPhone; iPad needs `popoverPresentationController.barButtonItem`
    /// to anchor the popover (otherwise it crashes with "must supply source view").
    @objc private func openThemePicker() {
        let currentID = Prefs.selectedTheme ?? GamepadTheme.all[0].id
        let alert = UIAlertController(title: "按键样式", message: nil, preferredStyle: .actionSheet)

        for theme in GamepadTheme.all {
            let action = UIAlertAction(title: theme.displayName, style: .default) { [weak self] _ in
                self?.applyTheme(theme)
            }
            if theme.id == currentID {
                // System checkmark on the currently active theme so the user always knows what
                // they're already using — avoids the "did my tap register?" feedback loop.
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        // iPad popover anchor. On iPhone this is a no-op (the anchor properties are ignored for
        // action sheets on compact horizontal size classes) but it prevents a crash on iPad.
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(alert, animated: true)
    }

    // MARK: - Pause / Reset

    @objc private func togglePause() {
        guard session.hasROM else { return }
        isPausedByUser.toggle()

        // Only the audio engine needs an explicit poke — the display link keeps ticking but
        // `tick()` skips the emulator step when paused, so the last framebuffer stays on screen.
        // Stopping audio too avoids a tight loop pumping zeros through the source node.
        if isPausedByUser {
            audioEngine?.pause()
            pauseButton?.image = UIImage(systemName: "play.fill")
            pauseButton?.accessibilityLabel = "Resume"
            statusLabel.text = "paused"
        } else {
            audioEngine?.resume()
            pauseButton?.image = UIImage(systemName: "pause.fill")
            pauseButton?.accessibilityLabel = "Pause"
            statusLabel.text = "running"
        }
    }

    @objc private func resetROM() {
        guard session.hasROM else { return }
        // Reset yanks the player out of whatever they were doing — always confirm.
        let alert = UIAlertController(
            title: "Reset ROM?",
            message: "Any unsaved progress will be lost.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            // Flush current SRAM before resetting — the core preserves battery RAM across
            // reset() by design (real hardware behavior), but the user is asking to restart the
            // game, and their in-game save should survive that restart. Snapshot now so a crash
            // during reset() doesn't leave the disk copy stale.
            self.sramStore.saveFromSession(self.session)
            if self.session.reset() {
                // Coming out of a paused state? Snap back to running so the user isn't surprised
                // by the game not moving after reset.
                if self.isPausedByUser { self.togglePause() }
                self.statusLabel.text = "reset"
            } else {
                self.statusLabel.text = "reset failed"
            }
        })
        present(alert, animated: true)
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
        // has explicitly paused via the toolbar button; the last frame stays on screen.
        if session.hasROM && !isPausedByUser {
            session.stepFrame()
        }
        metalView.draw()
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
            // Coming out of a paused state (either user pause OR the "no ROM yet" empty state)?
            // Snap back to running so the user isn't surprised by the game not moving after they
            // pick something from the library.
            if isPausedByUser {
                isPausedByUser = false
                pauseButton?.image = UIImage(systemName: "pause.fill")
                pauseButton?.accessibilityLabel = "Pause"
            }
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
