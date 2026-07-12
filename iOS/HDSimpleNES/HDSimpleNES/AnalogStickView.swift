//
//  AnalogStickView.swift
//  HDSimpleHappy
//
//  Drag-to-steer analog stick. Owns the entire touch surface: a filled outer ring for the base
//  and a smaller filled circle for the knob. When the user drags, the knob follows the finger
//  (clamped to the base radius). The stick maps the current knob offset to 8 direction events
//  using a dead-zone + angular octants, so a drag toward the upper-left presses UP and LEFT
//  simultaneously.
//
//  Not a UIControl subclass — the underlying gesture is a continuous drag, not a discrete
//  press-then-release event stream. We drive up/down/left/right state directly through the
//  `onDirectionChanged` callback and let TouchGamepadView forward it to the emulator core.
//
//  Direction dispatch rule:
//    - Compute the knob offset from center; if its magnitude is inside the dead zone (25% of
//      the base radius), all four directions are released.
//    - Otherwise convert the angle to one of 8 octants, each mapping to a {up,down,left,right}
//      subset. Diagonals fire two directions at once.
//    - On every change we diff the new subset vs the previous one and fire a callback for each
//      button whose pressed state flipped — no spamming the emulator with unchanged state.
//

import UIKit

final class AnalogStickView: UIView {

    /// Fires when a direction turns on or off. Delivered on the main thread; TouchGamepadView
    /// forwards it to the emulator's input queue.
    var onDirectionChanged: ((NESButton, Bool) -> Void)?

    private let baseLayer = CAShapeLayer()
    private let knobLayer = CAShapeLayer()
    private let idleColor: UIColor
    private let pressedColor: UIColor
    private let borderColor: UIColor

    /// Which of the 4 direction lines are currently held down. Reset to empty on touch-up so
    /// diagonals release cleanly.
    private var activeDirections: Set<NESButton> = []

    /// Dead-zone as a fraction of base radius. Tuned to 25% — small enough that a light drift
    /// still steers, large enough that a tap near center doesn't randomly fire a direction.
    private let deadZoneFraction: CGFloat = 0.25

    init(theme: GamepadTheme) {
        self.idleColor = theme.colors.idleBackground
        self.pressedColor = theme.colors.pressedBackground
        self.borderColor = theme.colors.border
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        isMultipleTouchEnabled = false

        baseLayer.fillColor = idleColor.withAlphaComponent(0.55).cgColor
        baseLayer.strokeColor = borderColor.cgColor
        baseLayer.lineWidth = 2
        layer.addSublayer(baseLayer)

        knobLayer.fillColor = idleColor.cgColor
        knobLayer.strokeColor = borderColor.cgColor
        knobLayer.lineWidth = 1
        layer.addSublayer(knobLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let baseRect = CGRect(x: (bounds.width - side) / 2,
                              y: (bounds.height - side) / 2,
                              width: side, height: side)
        baseLayer.path = UIBezierPath(ovalIn: baseRect).cgPath
        baseLayer.frame = bounds

        // Knob starts centered; touchesMoved overrides `knobLayer.frame` mid-drag with the
        // offset position, so this layoutSubviews only runs when we're idle or after touch-up.
        centerKnob()
    }

    /// Redraw the knob at (dx, dy) offset from the center, clamped to the base radius.
    private func placeKnob(offsetX: CGFloat, offsetY: CGFloat) {
        let side = min(bounds.width, bounds.height)
        let baseRadius = side / 2
        let knobDiameter = side * 0.45
        // Clamp offset magnitude to baseRadius - knobRadius so the knob edge never leaves the
        // base circle.
        let maxOffset = baseRadius - knobDiameter / 2
        let mag = sqrt(offsetX * offsetX + offsetY * offsetY)
        var dx = offsetX, dy = offsetY
        if mag > maxOffset && mag > 0 {
            dx = offsetX / mag * maxOffset
            dy = offsetY / mag * maxOffset
        }
        let cx = bounds.width / 2 + dx
        let cy = bounds.height / 2 + dy
        knobLayer.frame = CGRect(x: cx - knobDiameter / 2,
                                 y: cy - knobDiameter / 2,
                                 width: knobDiameter, height: knobDiameter)
        knobLayer.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: knobLayer.frame.size)).cgPath
    }

    private func centerKnob() {
        placeKnob(offsetX: 0, offsetY: 0)
        // Idle color — pressed color is applied on touch-down so the user sees feedback even
        // for a tap in the dead zone.
        knobLayer.fillColor = idleColor.cgColor
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        knobLayer.fillColor = pressedColor.cgColor
        handleTouch(at: t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        handleTouch(at: t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    private func handleTouch(at point: CGPoint) {
        let dx = point.x - bounds.width / 2
        let dy = point.y - bounds.height / 2
        placeKnob(offsetX: dx, offsetY: dy)
        updateDirections(dx: dx, dy: dy)
    }

    private func release() {
        // Fire release for every direction still held before clearing state, so the emulator
        // sees the up-transition and doesn't get stuck steering after touch-up.
        for d in activeDirections {
            onDirectionChanged?(d, false)
        }
        activeDirections.removeAll()
        centerKnob()
    }

    // MARK: - Direction math

    /// Convert the raw (dx, dy) offset to a set of pressed directions. Empty if inside dead zone.
    /// 8 octants, boundaries at multiples of 22.5° so cardinals get their own octant and diagonals
    /// each get a two-direction octant.
    private func directionSet(dx: CGFloat, dy: CGFloat) -> Set<NESButton> {
        let side = min(bounds.width, bounds.height)
        let radius = side / 2
        let mag = sqrt(dx * dx + dy * dy)
        if mag < radius * deadZoneFraction {
            return []
        }
        // atan2 returns radians in [-π, π]; we bucket into 8 octants of 45° each. Note the y
        // axis is UIKit's (positive down), so we negate dy so "up" comes out as +y and the
        // octant math reads naturally.
        let angle = atan2(-dy, dx)   // 0 = right, π/2 = up, ±π = left, -π/2 = down
        let twoPi = CGFloat.pi * 2
        // Rotate by π/8 (22.5°) so cardinal directions sit at the CENTER of their octant, not
        // at the boundary — a slight drift off center still counts as pure right/up/left/down.
        let normalized = (angle + twoPi + .pi / 8).truncatingRemainder(dividingBy: twoPi)
        let octant = Int(normalized / (.pi / 4))  // 0..7
        switch octant {
        case 0: return [.right]
        case 1: return [.right, .up]
        case 2: return [.up]
        case 3: return [.up, .left]
        case 4: return [.left]
        case 5: return [.left, .down]
        case 6: return [.down]
        case 7: return [.down, .right]
        default: return []
        }
    }

    /// Diff the new direction set against the last one and fire callbacks only for changes.
    private func updateDirections(dx: CGFloat, dy: CGFloat) {
        let desired = directionSet(dx: dx, dy: dy)
        // Released = in active but not desired.
        for d in activeDirections.subtracting(desired) {
            onDirectionChanged?(d, false)
        }
        // Pressed = in desired but not active.
        for d in desired.subtracting(activeDirections) {
            onDirectionChanged?(d, true)
        }
        activeDirections = desired
    }
}
