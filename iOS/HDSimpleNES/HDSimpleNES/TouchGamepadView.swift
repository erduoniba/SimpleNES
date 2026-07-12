//
//  TouchGamepadView.swift
//  HDSimpleHappy
//
//  On-screen touch controls: D-Pad + A/B + Select/Start. Reports state changes through a single
//  closure. Buttons keep a "sticky-until-touch-ends" model — press-in fires pressed=true, lift
//  fires pressed=false, and drag-outside also releases.
//
//  Themable — the LAYOUT is theme-driven, not just colors. A `GamepadTheme` is a flat array of
//  `Item` values authored in a `mappingSize` reference space; this view rebuilds all subviews
//  from that array on every theme swap and re-frames them in `layoutSubviews`. See
//  `GamepadTheme.swift` for the item model rationale.
//
//  Hit-testing extends per-item via `extendedEdges` (Delta-style): a button's touch region can
//  reach beyond its visible frame so fat-fingered taps still land — the visible surface stays
//  crisp while the invisible hit target grows outward.
//

import UIKit

final class TouchGamepadView: UIView {

    /// Called on any state change. Delivered on the main thread.
    var onButtonStateChanged: ((NESButton, Bool) -> Void)?

    /// The theme currently painted onto every button. Default = first entry of the catalog;
    /// swapped by `applyTheme(_:)`.
    private(set) var currentTheme: GamepadTheme = GamepadTheme.all[0]

    /// Every placed view + the Item it was built from. Regenerated on theme change, iterated
    /// on every `layoutSubviews` pass to compute frames from anchor/offset/size × current scale.
    private var placements: [Placement] = []

    private struct Placement {
        let view: UIView
        let item: GamepadTheme.Item
    }

    // MARK: - Button subclass

    /// Interactive button element. Owns its `Shape` (used for corner-radius math and font
    /// choice) and its `extendedEdges` (grows the hit rectangle without changing the drawn
    /// frame).
    fileprivate final class GamepadButton: UIControl {

        let nesButton: NESButton
        var onStateChanged: ((NESButton, Bool) -> Void)?

        /// If true, this button's IDLE background is forced transparent (used by the cross
        /// D-pad arrow items — the visible surface is the plus-shape backing behind them).
        /// Pressed state still flashes normally so the user sees their tap register.
        var forceTransparentIdle: Bool = false

        /// How far outside `bounds` the touch region reaches. Positive values grow it.
        var extendedEdges: UIEdgeInsets

        private let label = UILabel()
        private let shape: GamepadTheme.Shape

        /// The style + colors currently in effect. Refreshed by `apply(theme:)`.
        private var currentStyle: GamepadTheme.Style = .flat
        private var idleBackground: UIColor = UIColor.secondarySystemFill
        private var pressedBackground: UIColor = UIColor.systemBlue.withAlphaComponent(0.35)
        private var borderColor: UIColor = UIColor.separator
        private var textColor: UIColor = .label

        /// Extra visual sublayers owned by this button. Ownership matters because we tear them
        /// down when the style changes.
        private var raisedHighlightLayer: CAGradientLayer?
        private var glassBlurView: UIVisualEffectView?

        init(nesButton: NESButton, title: String, shape: GamepadTheme.Shape, extendedEdges: UIEdgeInsets) {
            self.nesButton = nesButton
            self.shape = shape
            self.extendedEdges = extendedEdges
            super.init(frame: .zero)
            // Frame-based layout — we're placed by the parent view's layoutSubviews().
            translatesAutoresizingMaskIntoConstraints = true

            backgroundColor = idleBackground
            layer.borderColor = borderColor.cgColor
            layer.borderWidth = 1
            layer.masksToBounds = true

            label.text = title
            label.textAlignment = .center
            label.textColor = textColor
            // Small font for the long pill/rectangle labels; larger font for the round buttons
            // and D-pad arrows.
            let fontSize: CGFloat
            switch shape {
            case .pill, .rectangle:                                              fontSize = 12
            case .dpadArrow, .circle, .roundedSquare, .plusCross, .stickBase, .discPad: fontSize = 18
            }
            label.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            addTarget(self, action: #selector(handlePressDown), for: [.touchDown, .touchDragEnter])
            addTarget(self, action: #selector(handleRelease), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Repaint this button with the given theme. Handles STYLE transitions too: removes any
        /// old-style scaffolding (gradient overlay, blur view, drop shadow) before installing
        /// the new one. Called once per button from `rebuildForTheme`.
        func apply(theme: GamepadTheme) {
            currentStyle = theme.style
            idleBackground = theme.colors.idleBackground
            pressedBackground = theme.colors.pressedBackground
            borderColor = theme.colors.border
            textColor = theme.colors.text

            raisedHighlightLayer?.removeFromSuperlayer()
            raisedHighlightLayer = nil
            glassBlurView?.removeFromSuperview()
            glassBlurView = nil
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowOffset = .zero
            layer.masksToBounds = true

            label.textColor = textColor
            backgroundColor = resolveIdleBackground()

            switch theme.style {
            case .flat:
                layer.borderWidth = 1
                layer.borderColor = borderColor.cgColor

            case .raised:
                layer.borderWidth = 1
                layer.borderColor = borderColor.cgColor
                let hl = CAGradientLayer()
                hl.colors = [
                    UIColor(white: 1.0, alpha: 0.32).cgColor,
                    UIColor(white: 1.0, alpha: 0.00).cgColor,
                    UIColor(white: 0.0, alpha: 0.15).cgColor,
                ]
                hl.locations = [0.0, 0.55, 1.0]
                hl.startPoint = CGPoint(x: 0.5, y: 0)
                hl.endPoint = CGPoint(x: 0.5, y: 1)
                layer.insertSublayer(hl, at: 0)
                raisedHighlightLayer = hl
                layer.masksToBounds = false
                layer.shadowColor = UIColor.black.cgColor
                layer.shadowOpacity = 0.35
                layer.shadowRadius = 3
                layer.shadowOffset = CGSize(width: 0, height: 2)

            case .neon:
                layer.borderWidth = 2
                layer.borderColor = borderColor.cgColor
                layer.masksToBounds = false
                layer.shadowColor = borderColor.cgColor
                layer.shadowOpacity = 0.85
                layer.shadowRadius = 8
                layer.shadowOffset = .zero

            case .pixel:
                layer.borderWidth = 3
                layer.borderColor = borderColor.cgColor

            case .glass:
                layer.borderWidth = 1
                layer.borderColor = borderColor.cgColor
                let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
                blur.translatesAutoresizingMaskIntoConstraints = false
                blur.isUserInteractionEnabled = false
                insertSubview(blur, at: 0)
                NSLayoutConstraint.activate([
                    blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                    blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                    blur.topAnchor.constraint(equalTo: topAnchor),
                    blur.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                glassBlurView = blur
            }
            setNeedsLayout()
        }

        /// The color the button paints when NOT pressed. Normally `idleBackground`, but the
        /// unified cross D-pad forces its 4 arrows transparent so the cross shape shows through.
        private func resolveIdleBackground() -> UIColor {
            return forceTransparentIdle ? .clear : idleBackground
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // Corner radius = shape × style. Pixel style forces zero regardless of shape (8-bit
            // UI look). Everything else follows the button's declared shape.
            let radius: CGFloat
            switch (currentStyle, shape) {
            case (.pixel, _):                          radius = 0
            case (_, .circle):                         radius = min(bounds.width, bounds.height) / 2
            case (_, .pill):                           radius = bounds.height / 2
            case (_, .dpadArrow):                      radius = 6
            case (_, .rectangle):                      radius = 3
            case (_, .roundedSquare(let r)):           radius = r
            case (_, .plusCross):                      radius = 0   // not used — plusCross never renders as a button
            case (_, .stickBase), (_, .discPad):       radius = 0   // not used — stick/disc use dedicated views
            }
            layer.cornerRadius = radius

            raisedHighlightLayer?.frame = bounds
            raisedHighlightLayer?.cornerRadius = radius
            glassBlurView?.layer.cornerRadius = radius
            glassBlurView?.clipsToBounds = true

            if !layer.masksToBounds && layer.shadowOpacity > 0 {
                layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
            } else {
                layer.shadowPath = nil
            }
        }

        /// Grow the hit rectangle by `extendedEdges`. Positive insets extend outward — Delta's
        /// convention. Called by the runtime during hit-testing.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let hitRect = bounds.inset(by: UIEdgeInsets(
                top: -extendedEdges.top,
                left: -extendedEdges.left,
                bottom: -extendedEdges.bottom,
                right: -extendedEdges.right))
            return hitRect.contains(point)
        }

        // Do NOT name these `pressDown` / `release` — `release` in particular collides with the
        // NSObject `-release` selector and turns every ARC dealloc into a recursive setBackground
        // call. Prefixing with `handle` sidesteps the entire ObjC-runtime naming space.
        @objc private func handlePressDown() {
            backgroundColor = pressedBackground
            onStateChanged?(nesButton, true)
        }

        @objc private func handleRelease() {
            backgroundColor = resolveIdleBackground()
            onStateChanged?(nesButton, false)
        }
    }

    // MARK: - Unified cross D-pad backing view

    /// The visible plus-shape drawn BEHIND the 4 transparent D-pad direction buttons for themes
    /// that include a `.dpadCrossBacking` item. Non-interactive — hits pass through to the arrow
    /// buttons above it.
    private final class CrossBackingView: UIView {
        private let shapeLayer = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            translatesAutoresizingMaskIntoConstraints = true
            isUserInteractionEnabled = false  // The 4 arrow buttons on top handle touches.
            layer.addSublayer(shapeLayer)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Repaint using the button-idle color as the cross fill and border as the outline.
        /// Called after every theme change; the layout pass then updates the path when bounds
        /// finally settle.
        func apply(fill: UIColor, border: UIColor, style: GamepadTheme.Style) {
            shapeLayer.fillColor = fill.cgColor
            shapeLayer.strokeColor = border.cgColor
            shapeLayer.lineWidth = style == .pixel ? 3 : 1
            // Neon glow around the cross itself — same treatment as button borders.
            if style == .neon {
                layer.shadowColor = border.cgColor
                layer.shadowOpacity = 0.85
                layer.shadowRadius = 8
                layer.shadowOffset = .zero
                layer.masksToBounds = false
            } else {
                layer.shadowOpacity = 0
                layer.masksToBounds = true
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            shapeLayer.frame = bounds
            // Plus sign spanning the full bounds, arms are 1/3 of the shorter dimension.
            let armThickness = min(bounds.width, bounds.height) / 3
            let midX = bounds.width / 2, midY = bounds.height / 2
            let path = UIBezierPath()
            path.append(UIBezierPath(rect: CGRect(x: 0, y: midY - armThickness/2,
                                                  width: bounds.width, height: armThickness)))
            path.append(UIBezierPath(rect: CGRect(x: midX - armThickness/2, y: 0,
                                                  width: armThickness, height: bounds.height)))
            shapeLayer.path = path.cgPath
            // Neon needs its shadowPath too, using the same plus.
            if layer.shadowOpacity > 0 {
                layer.shadowPath = path.cgPath
            }
        }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        rebuildForTheme(currentTheme)
    }

    required init?(coder: NSCoder) { fatalError() }

    // In landscape the gamepad view OVERLAYS the entire safe area, and the transparent gaps
    // between D-pad / A-B / Start-Select would otherwise still absorb touches. Report only points
    // that would actually hit a subview (respecting each button's extendedEdges).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for sub in subviews {
            guard sub.isUserInteractionEnabled else { continue }
            let p = convert(point, to: sub)
            if sub.point(inside: p, with: event) {
                return true
            }
        }
        return false
    }

    // MARK: - Theme swap

    /// Full rebuild: remove every subview, forget them, and rebuild from the theme's items[].
    /// Cheap on iOS — a handful of frames, no images. Called from init with the default theme,
    /// and from ViewController when the user picks a theme.
    func applyTheme(_ theme: GamepadTheme) {
        currentTheme = theme
        rebuildForTheme(theme)
    }

    private func rebuildForTheme(_ theme: GamepadTheme) {
        for sub in subviews { sub.removeFromSuperview() }
        placements.removeAll(keepingCapacity: true)

        // Emit non-interactive backings first so the cross plus paints UNDERNEATH the arrow
        // buttons regardless of their order in the theme's array.
        let ordered = theme.items.sorted { lhs, rhs in
            zOrder(for: lhs.role) < zOrder(for: rhs.role)
        }

        for item in ordered {
            let v = makeView(for: item, theme: theme)
            addSubview(v)
            placements.append(Placement(view: v, item: item))
        }

        setNeedsLayout()
    }

    /// Higher values sit on top. Backings at 0, decorations at 1, buttons at 2 — a fat-fingered
    /// arrow-tap on a cross theme wins the hit test over the plus behind it.
    private func zOrder(for role: GamepadTheme.Role) -> Int {
        switch role {
        case .dpadCrossBacking:            return 0
        case .decoration:                  return 1
        default:                           return 2
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = currentTheme.mappingSize
        // Uniform down-scale ONLY if our bounds can't fit the mapping on either axis. When the
        // gamepad view is same-or-larger (typical portrait + all landscape overlays), items keep
        // their authored point sizes and just re-anchor to the current corners.
        let scale: CGFloat
        if bounds.width < m.width || bounds.height < m.height {
            scale = min(bounds.width / m.width, bounds.height / m.height, 1)
        } else {
            scale = 1
        }
        for p in placements {
            p.view.frame = frame(for: p.item, in: bounds, scale: scale)
        }
    }

    /// Compute an item's frame in `bounds`. Axis directions vary by anchor — see the enum's docs.
    private func frame(for item: GamepadTheme.Item, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let w = item.size.width * scale
        let h = item.size.height * scale
        let ox = item.offset.x * scale
        let oy = item.offset.y * scale
        let x: CGFloat
        let y: CGFloat
        switch item.anchor {
        case .topLeft:      x = ox;                          y = oy
        case .topRight:     x = bounds.width - ox - w;       y = oy
        case .bottomLeft:   x = ox;                          y = bounds.height - oy - h
        case .bottomRight:  x = bounds.width - ox - w;       y = bounds.height - oy - h
        case .bottomCenter: x = bounds.width / 2 + ox - w/2; y = bounds.height - oy - h
        case .topCenter:    x = bounds.width / 2 + ox - w/2; y = oy
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Per-item view construction

    private func makeView(for item: GamepadTheme.Item, theme: GamepadTheme) -> UIView {
        switch item.role {
        case .dpadCrossBacking:
            let v = CrossBackingView()
            v.apply(fill: theme.colors.idleBackground,
                    border: theme.colors.border,
                    style: theme.style)
            return v

        case .dpadStick:
            // Analog stick — one custom view that owns the drag surface and fans out to 4
            // direction events (diagonals fire two). Not a regular button; can't be pressed by
            // a discrete tap on the label — must be dragged from its center.
            let v = AnalogStickView(theme: theme)
            v.onDirectionChanged = { [weak self] btn, pressed in
                self?.onButtonStateChanged?(btn, pressed)
            }
            return v

        case .dpadDisc:
            // Octagonal 8-way disc — hit-tests 8 sectors. Diagonals fire two adjacent direction
            // events simultaneously so up-left presses both up AND left.
            let v = DiscPadView(theme: theme)
            v.onDirectionChanged = { [weak self] btn, pressed in
                self?.onButtonStateChanged?(btn, pressed)
            }
            return v

        case .decoration(let text):
            let l = UILabel()
            l.text = text
            l.textAlignment = .center
            l.textColor = theme.colors.text
            l.font = UIFont.systemFont(ofSize: 12, weight: .heavy)
            l.isUserInteractionEnabled = false
            return l

        default:
            guard let nes = nesButton(for: item.role) else {
                return UIView()
            }
            let btn = GamepadButton(nesButton: nes,
                                    title: label(for: item.role),
                                    shape: item.shape,
                                    extendedEdges: item.extendedEdges)
            btn.onStateChanged = { [weak self] b, pressed in
                self?.onButtonStateChanged?(b, pressed)
            }
            if isDpadArrow(role: item.role) && themeIncludesCrossBacking(theme) {
                btn.forceTransparentIdle = true
                btn.apply(theme: theme)
                btn.layer.borderWidth = 0
            } else {
                btn.apply(theme: theme)
            }
            return btn
        }
    }

    /// True iff the given role is one of the four D-pad direction arrows.
    private func isDpadArrow(role: GamepadTheme.Role) -> Bool {
        switch role {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        default: return false
        }
    }

    /// True iff this theme has a `.dpadCrossBacking` item — used to decide whether the arrow
    /// buttons should paint transparent-idle.
    private func themeIncludesCrossBacking(_ theme: GamepadTheme) -> Bool {
        return theme.items.contains { item in
            if case .dpadCrossBacking = item.role { return true }
            return false
        }
    }

    /// Map a Role to the NES input line it should drive. Returns nil for non-interactive roles.
    /// X and Y both map to A / B respectively — the NES has only two action buttons, so the
    /// diamond layout is a visual convention rather than four independent inputs.
    private func nesButton(for role: GamepadTheme.Role) -> NESButton? {
        switch role {
        case .dpadUp:    return .up
        case .dpadDown:  return .down
        case .dpadLeft:  return .left
        case .dpadRight: return .right
        case .a:         return .a
        case .b:         return .b
        case .x:         return .a   // X → A (diamond convention)
        case .y:         return .b   // Y → B (diamond convention)
        case .select:    return .select
        case .start:     return .start
        case .dpadCrossBacking, .dpadStick, .dpadDisc, .decoration: return nil
        }
    }

    /// Glyph/text a button role paints on its face.
    private func label(for role: GamepadTheme.Role) -> String {
        switch role {
        case .dpadUp:    return "▲"
        case .dpadDown:  return "▼"
        case .dpadLeft:  return "◀"
        case .dpadRight: return "▶"
        case .a:         return "A"
        case .b:         return "B"
        case .x:         return "X"
        case .y:         return "Y"
        case .select:    return "SELECT"
        case .start:     return "START"
        case .dpadCrossBacking, .dpadStick, .dpadDisc, .decoration: return ""
        }
    }
}
