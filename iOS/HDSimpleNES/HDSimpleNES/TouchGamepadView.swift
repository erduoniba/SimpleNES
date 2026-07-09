//
//  TouchGamepadView.swift
//  HDSimpleNES
//
//  On-screen touch controls: D-Pad + A/B + Select/Start. Reports state changes through a single
//  closure. Buttons keep a "sticky-until-touch-ends" model — press-in fires pressed=true, lift
//  fires pressed=false, and drag-outside also releases.
//

import UIKit

final class TouchGamepadView: UIView {

    /// Called on any state change. Delivered on the main thread.
    var onButtonStateChanged: ((NESButton, Bool) -> Void)?

    // MARK: - Button subclass

    private final class GamepadButton: UIControl {
        let nesButton: NESButton
        var onStateChanged: ((NESButton, Bool) -> Void)?

        private let label = UILabel()
        private let shape: Shape

        enum Shape { case round, pill, dpad }

        init(nesButton: NESButton, title: String, shape: Shape) {
            self.nesButton = nesButton
            self.shape = shape
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            backgroundColor = UIColor.secondarySystemFill
            layer.borderColor = UIColor.separator.cgColor
            layer.borderWidth = 1

            label.text = title
            label.textAlignment = .center
            label.textColor = .label
            label.font = UIFont.systemFont(ofSize: shape == .pill ? 12 : 18, weight: .semibold)
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

        override func layoutSubviews() {
            super.layoutSubviews()
            switch shape {
            case .round: layer.cornerRadius = min(bounds.width, bounds.height) / 2
            case .pill:  layer.cornerRadius = bounds.height / 2
            case .dpad:  layer.cornerRadius = 6
            }
        }

        // Do NOT name these `pressDown` / `release` — `release` in particular collides with the
        // NSObject `-release` selector and turns every ARC dealloc into a recursive setBackground
        // call. Prefixing with `handle` sidesteps the entire ObjC-runtime naming space.
        @objc private func handlePressDown() {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.35)
            onStateChanged?(nesButton, true)
        }

        @objc private func handleRelease() {
            backgroundColor = UIColor.secondarySystemFill
            onStateChanged?(nesButton, false)
        }
    }

    // MARK: - Layout

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ nes: NESButton, _ title: String, _ shape: GamepadButton.Shape) -> GamepadButton {
        let b = GamepadButton(nesButton: nes, title: title, shape: shape)
        b.onStateChanged = { [weak self] btn, pressed in
            self?.onButtonStateChanged?(btn, pressed)
        }
        return b
    }

    private func buildLayout() {
        // D-Pad — a 3×3 grid with the 4 arrows in cardinal positions. Corners are empty spacer
        // views (invisible, non-interactive) so the up/down/left/right pieces sit flush and
        // there's no accidental diagonal press.
        let up    = makeButton(.up,    "▲", .dpad)
        let down  = makeButton(.down,  "▼", .dpad)
        let left  = makeButton(.left,  "◀", .dpad)
        let right = makeButton(.right, "▶", .dpad)

        let dpad = UIView()
        dpad.translatesAutoresizingMaskIntoConstraints = false
        dpad.addSubview(up); dpad.addSubview(down); dpad.addSubview(left); dpad.addSubview(right)
        NSLayoutConstraint.activate([
            // Layout inside a 150×150 pad — each button 50×50 in the correct cell.
            dpad.widthAnchor.constraint(equalToConstant: 150),
            dpad.heightAnchor.constraint(equalToConstant: 150),

            up.centerXAnchor.constraint(equalTo: dpad.centerXAnchor),
            up.topAnchor.constraint(equalTo: dpad.topAnchor),
            up.widthAnchor.constraint(equalToConstant: 50),
            up.heightAnchor.constraint(equalToConstant: 50),

            down.centerXAnchor.constraint(equalTo: dpad.centerXAnchor),
            down.bottomAnchor.constraint(equalTo: dpad.bottomAnchor),
            down.widthAnchor.constraint(equalToConstant: 50),
            down.heightAnchor.constraint(equalToConstant: 50),

            left.centerYAnchor.constraint(equalTo: dpad.centerYAnchor),
            left.leadingAnchor.constraint(equalTo: dpad.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 50),
            left.heightAnchor.constraint(equalToConstant: 50),

            right.centerYAnchor.constraint(equalTo: dpad.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: dpad.trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: 50),
            right.heightAnchor.constraint(equalToConstant: 50),
        ])

        // A / B on the right — round buttons.
        let bBtn = makeButton(.b, "B", .round)
        let aBtn = makeButton(.a, "A", .round)
        let abStack = UIStackView(arrangedSubviews: [bBtn, aBtn])
        abStack.axis = .horizontal
        abStack.spacing = 20
        abStack.alignment = .center
        abStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bBtn.widthAnchor.constraint(equalToConstant: 64),
            bBtn.heightAnchor.constraint(equalToConstant: 64),
            aBtn.widthAnchor.constraint(equalToConstant: 64),
            aBtn.heightAnchor.constraint(equalToConstant: 64),
        ])

        // Select / Start in the center.
        let selectBtn = makeButton(.select, "SELECT", .pill)
        let startBtn = makeButton(.start,  "START",  .pill)
        let selStartStack = UIStackView(arrangedSubviews: [selectBtn, startBtn])
        selStartStack.axis = .horizontal
        selStartStack.spacing = 12
        selStartStack.alignment = .center
        selStartStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            selectBtn.widthAnchor.constraint(equalToConstant: 74),
            selectBtn.heightAnchor.constraint(equalToConstant: 28),
            startBtn.widthAnchor.constraint(equalToConstant: 74),
            startBtn.heightAnchor.constraint(equalToConstant: 28),
        ])

        addSubview(dpad)
        addSubview(abStack)
        addSubview(selStartStack)

        NSLayoutConstraint.activate([
            // D-pad in the bottom-left group.
            dpad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            dpad.centerYAnchor.constraint(equalTo: centerYAnchor),

            // A/B in the bottom-right group.
            abStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            abStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Select/Start centered horizontally at the bottom.
            selStartStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            selStartStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
}
