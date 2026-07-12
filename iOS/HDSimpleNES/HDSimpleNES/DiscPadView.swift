//
//  DiscPadView.swift
//  HDSimpleHappy
//
//  Octagonal 8-way D-pad. One touch surface hit-tests into 8 sectors (each 45° wide); cardinal
//  sectors press one direction, diagonal sectors press two. Unlike AnalogStickView the disc is
//  static — no moving knob — so it feels like a PlayStation D-pad rather than a Xbox stick.
//
//  Visual: dark octagonal fill + border, with a highlighted wedge under the finger showing which
//  sector is active. Non-active state shows just the octagon outline with 4 small direction
//  chevrons at the cardinal points to hint the geometry.
//
//  Direction dispatch reuses the same 8-octant math as AnalogStickView (see that file for
//  details); the only difference here is that the touch position IS the pressed sector — no
//  drag semantics, no dead zone. A finger down anywhere on the disc immediately presses the
//  sector under it.
//

import UIKit

final class DiscPadView: UIView {

    var onDirectionChanged: ((NESButton, Bool) -> Void)?

    private let discLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let idleColor: UIColor
    private let pressedColor: UIColor
    private let borderColor: UIColor
    private let textColor: UIColor

    private var activeDirections: Set<NESButton> = []

    /// Small "▲▶▼◀" chevrons drawn at the cardinal points. Redrawn on layout change; hidden
    /// while the disc is pressed so they don't clash with the highlighted wedge.
    private let chevronsLayer = CATextLayer()

    init(theme: GamepadTheme) {
        self.idleColor = theme.colors.idleBackground
        self.pressedColor = theme.colors.pressedBackground
        self.borderColor = theme.colors.border
        self.textColor = theme.colors.text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        isMultipleTouchEnabled = false

        discLayer.fillColor = idleColor.cgColor
        discLayer.strokeColor = borderColor.cgColor
        discLayer.lineWidth = 2
        layer.addSublayer(discLayer)

        highlightLayer.fillColor = pressedColor.withAlphaComponent(0.85).cgColor
        highlightLayer.strokeColor = UIColor.clear.cgColor
        highlightLayer.opacity = 0
        layer.addSublayer(highlightLayer)

        // Chevrons — a single centered CATextLayer with all four glyphs positioned via the
        // string layout. Simpler and cheaper than four separate layers, and any theme-driven
        // font/color change flows through here in one place.
        chevronsLayer.string = ""     // filled in layoutSubviews once we know the size.
        chevronsLayer.foregroundColor = textColor.withAlphaComponent(0.6).cgColor
        chevronsLayer.alignmentMode = .center
        chevronsLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(chevronsLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let rect = CGRect(x: (bounds.width - side) / 2,
                          y: (bounds.height - side) / 2,
                          width: side, height: side)
        let octPath = octagonPath(in: rect)
        discLayer.frame = bounds
        discLayer.path = octPath.cgPath
        highlightLayer.frame = bounds
        chevronsLayer.frame = rect
        renderChevrons(side: side)
    }

    /// Build a regular octagon inscribed in `rect`.
    private func octagonPath(in rect: CGRect) -> UIBezierPath {
        let cx = rect.midX, cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        let path = UIBezierPath()
        // Start at the top vertex; step around 8 vertices 45° apart.
        for i in 0..<8 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 4
            let x = cx + cos(angle) * r
            let y = cy + sin(angle) * r
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.close()
        return path
    }

    private func renderChevrons(side: CGFloat) {
        // Two lines with the chevrons roughly at the disc's cardinal edges. Kept simple — a
        // fixed centered layout that reads "◀ ▶" flanking a middle row and "▲/▼" as separate
        // rows. Not pixel-perfect on the octagon vertices but visually clear.
        let attr = NSMutableAttributedString(string: "▲\n◀       ▶\n▼")
        let font = UIFont.systemFont(ofSize: side * 0.11, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = side * 0.14
        attr.addAttributes([
            .font: font,
            .foregroundColor: textColor.withAlphaComponent(0.55),
            .paragraphStyle: para,
        ], range: NSRange(location: 0, length: attr.length))
        chevronsLayer.string = attr
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        chevronsLayer.opacity = 0
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
        let (dirs, octant) = octantAndDirections(dx: dx, dy: dy)
        highlightSector(octant: octant)
        updateDirections(desired: dirs)
    }

    private func release() {
        for d in activeDirections {
            onDirectionChanged?(d, false)
        }
        activeDirections.removeAll()
        highlightLayer.opacity = 0
        chevronsLayer.opacity = 1
    }

    // MARK: - Direction / sector math

    /// Same 8-octant scheme as AnalogStickView — see that file for the rationale. Returns the
    /// direction subset and the octant index (0..7) so the caller can highlight the matching
    /// wedge.
    private func octantAndDirections(dx: CGFloat, dy: CGFloat) -> (Set<NESButton>, Int) {
        let mag = sqrt(dx * dx + dy * dy)
        // Disc has no dead zone — any press inside the bounds picks a sector. Guard mag==0
        // (finger exactly on center) with an arbitrary default (right).
        if mag < 1 { return ([.right], 0) }
        let angle = atan2(-dy, dx)
        let twoPi = CGFloat.pi * 2
        let normalized = (angle + twoPi + .pi / 8).truncatingRemainder(dividingBy: twoPi)
        let octant = Int(normalized / (.pi / 4))
        let dirs: Set<NESButton>
        switch octant {
        case 0: dirs = [.right]
        case 1: dirs = [.right, .up]
        case 2: dirs = [.up]
        case 3: dirs = [.up, .left]
        case 4: dirs = [.left]
        case 5: dirs = [.left, .down]
        case 6: dirs = [.down]
        case 7: dirs = [.down, .right]
        default: dirs = []
        }
        return (dirs, octant)
    }

    /// Paint a 45° pie slice matching the pressed octant so the user can see which sector fired.
    private func highlightSector(octant: Int) {
        let side = min(bounds.width, bounds.height)
        let rect = CGRect(x: (bounds.width - side) / 2,
                          y: (bounds.height - side) / 2,
                          width: side, height: side)
        let cx = rect.midX, cy = rect.midY
        let r = side / 2
        // Octant N spans angles [N*45° - 22.5°, N*45° + 22.5°] in the same convention as the
        // math above (0° = right, positive angle = up because we negate dy elsewhere).
        // Convert back to UIKit's y-down coordinate space by negating the sin() term.
        let centerAngleMath = CGFloat(octant) * .pi / 4         // math-space angle
        let startMath = centerAngleMath - .pi / 8
        let endMath = centerAngleMath + .pi / 8
        // UIBezierPath uses UIKit's y-down convention where positive angles are clockwise. Flip
        // the sign so a "math angle up" becomes a "UIKit angle up".
        let startUI = -endMath
        let endUI = -startMath
        let path = UIBezierPath()
        path.move(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx + cos(-startMath) * r, y: cy + sin(-startMath) * r))
        path.addArc(withCenter: CGPoint(x: cx, y: cy),
                    radius: r,
                    startAngle: startUI,
                    endAngle: endUI,
                    clockwise: true)
        path.close()
        highlightLayer.path = path.cgPath
        highlightLayer.opacity = 1
    }

    private func updateDirections(desired: Set<NESButton>) {
        for d in activeDirections.subtracting(desired) {
            onDirectionChanged?(d, false)
        }
        for d in desired.subtracting(activeDirections) {
            onDirectionChanged?(d, true)
        }
        activeDirections = desired
    }
}
