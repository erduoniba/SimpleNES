//
//  GamepadTheme.swift
//  HDSimpleHappy
//
//  Skin definitions for the on-screen touch controls. A theme is a flat **items[] array**
//  authored in a reference `mappingSize` coordinate space; TouchGamepadView scales and
//  anchor-places each item at layout time.
//
//  This file was rewritten around "真正不同的虚拟手柄" — four presets that differ in the
//  ACTUAL INPUT SURFACE, not just colors:
//    - 经典十字键 (Classic Cross): 4 separated arrow keys + round A/B — classic NES.
//    - 虚拟摇杆 (Analog Stick): a drag-to-steer round pad on the left, dispatches 8-way
//      direction events via TouchGamepadView.AnalogStickView. Right side is A/B round.
//    - 圆盘 8 向 (Disc Pad): a one-piece octagonal disc on the left that hit-tests 8
//      sectors, letting diagonal presses fire two direction events (up+left etc.). Right
//      side is A/B round.
//    - 街机四键 (Arcade Diamond): SNES-style A/B/X/Y diamond on the right (X→A, Y→B on
//      the NES which has only two action buttons). Left is a separated D-pad. Bigger
//      buttons overall — the "large size" variant in the same theme.
//
//  New roles vs the old model:
//    - `.dpadStick` — one item that owns the whole analog-stick surface. Rendered by a
//      dedicated AnalogStickView; taps/drags produce up/down/left/right events (with
//      simultaneous pairs for diagonals). Not a regular button.
//    - `.dpadDisc` — one item that owns an octagonal 8-way disc. Rendered by DiscPadView;
//      the eight sectors dispatch 1 or 2 direction events each (diagonals fire two).
//    - `.x`, `.y` — extra face buttons that MAP BACK to A / B respectively (NES only has
//      two action inputs). Labeled X/Y for the familiar SNES/Xbox diamond, wired to the
//      same input lines as A/B under the hood.
//    - `.dpadCrossBacking` is kept for backward compatibility but none of the new themes
//      use it. Ok to remove later.
//
//  Applied at two places (unchanged):
//    1. TouchGamepadView.applyTheme(_:) — rebuilds the view hierarchy from items[].
//    2. Prefs.setSelectedTheme(_:) — persists the choice by ID.
//

import UIKit

/// A single controller skin: items[] + visual style + colors. See file header.
struct GamepadTheme {

    /// Stable string ID for UserDefaults storage. Adding a theme: extend this enum + `all`.
    enum ID: String, CaseIterable {
        case classicCross    = "classic-cross"
        case analogStick     = "analog-stick"
        case discPad         = "disc-pad"
        case arcadeDiamond   = "arcade-diamond"
    }

    /// Visual treatment. Controls border weight, shadow, gradient overlay, and (for glass) blur.
    enum Style {
        case flat
        case raised
        case neon
        case pixel
        case glass
    }

    struct Colors {
        let idleBackground: UIColor
        let pressedBackground: UIColor
        let border: UIColor
        let text: UIColor
    }

    /// Which conceptual button (or non-interactive element) an Item represents. TouchGamepadView
    /// switches on this to decide (a) whether to wire it to the NES input line, (b) what label
    /// glyph to draw, (c) whether to use a special custom view class.
    enum Role {
        case dpadUp, dpadDown, dpadLeft, dpadRight
        /// Legacy: unified plus-shape backing behind the four dpad arrows. Kept for compat, not
        /// used by any of the new themes.
        case dpadCrossBacking
        /// One-piece analog stick. Owns the entire drag surface and emits up/down/left/right
        /// events (diagonals emit two at once).
        case dpadStick
        /// One-piece 8-way octagonal disc. Emits 1 or 2 direction events per press based on
        /// which of 8 sectors the touch falls in.
        case dpadDisc
        case a, b, select, start
        /// Extra face buttons. On the NES `.x` maps to A and `.y` maps to B — the diamond is a
        /// familiar visual layout, not extra input lines.
        case x, y
        case decoration(String)
    }

    enum Anchor {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case bottomCenter
        case topCenter
    }

    /// Geometric shape of an item's fill area.
    enum Shape {
        case dpadArrow
        case circle
        case roundedSquare(cornerRadius: CGFloat)
        case pill
        case rectangle
        /// Legacy plus-shape backing (see `.dpadCrossBacking`).
        case plusCross
        /// Analog stick base — outer ring + inner knob rendered by AnalogStickView.
        case stickBase
        /// Octagonal 8-way disc rendered by DiscPadView.
        case discPad
    }

    struct Item {
        let role: Role
        let anchor: Anchor
        let offset: CGPoint
        let size: CGSize
        let shape: Shape
        let extendedEdges: UIEdgeInsets
    }

    let id: ID
    let displayName: String
    let style: Style
    let colors: Colors
    let mappingSize: CGSize
    let items: [Item]

    // MARK: - Item factories
    //
    // Reusable building blocks. Themes concatenate a directional block + an action-button block
    // + a select/start block. Coordinates are in `mappingSize` points and were tuned against
    // the 414×260 reference canvas.

    /// 4 separated arrow blocks in the bottom-left corner. Baseline D-pad (no cross backing).
    private static func separatedDpad(size: CGFloat = 50) -> [Item] {
        let gap: CGFloat = size          // spacing between opposite arrows
        let baseX: CGFloat = 20
        let baseY: CGFloat = 55
        return [
            Item(role: .dpadUp,    anchor: .bottomLeft, offset: CGPoint(x: baseX + size,       y: baseY + gap * 2), size: CGSize(width: size, height: size), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)),
            Item(role: .dpadDown,  anchor: .bottomLeft, offset: CGPoint(x: baseX + size,       y: baseY),           size: CGSize(width: size, height: size), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)),
            Item(role: .dpadLeft,  anchor: .bottomLeft, offset: CGPoint(x: baseX,              y: baseY + gap),     size: CGSize(width: size, height: size), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 0)),
            Item(role: .dpadRight, anchor: .bottomLeft, offset: CGPoint(x: baseX + size * 2,   y: baseY + gap),     size: CGSize(width: size, height: size), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 8)),
        ]
    }

    /// One analog stick (single item, custom view).
    private static func analogStick(diameter: CGFloat = 160) -> [Item] {
        return [
            Item(role: .dpadStick, anchor: .bottomLeft,
                 offset: CGPoint(x: 20, y: 50),
                 size: CGSize(width: diameter, height: diameter),
                 shape: .stickBase,
                 extendedEdges: .zero),
        ]
    }

    /// One octagonal 8-way disc (single item, custom view).
    private static func discPad(diameter: CGFloat = 160) -> [Item] {
        return [
            Item(role: .dpadDisc, anchor: .bottomLeft,
                 offset: CGPoint(x: 20, y: 50),
                 size: CGSize(width: diameter, height: diameter),
                 shape: .discPad,
                 extendedEdges: .zero),
        ]
    }

    /// A/B horizontal, round. B on the left, A on the right.
    private static func horizontalAB(size: CGFloat = 64) -> [Item] {
        return [
            Item(role: .b, anchor: .bottomRight, offset: CGPoint(x: size + 40, y: 98), size: CGSize(width: size, height: size), shape: .circle, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
            Item(role: .a, anchor: .bottomRight, offset: CGPoint(x: 20,        y: 98), size: CGSize(width: size, height: size), shape: .circle, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
        ]
    }

    /// A/B/X/Y diamond (SNES-style). Anchored bottom-right. X and Y are wired to A/B under
    /// the hood — the diamond is a layout choice, not extra input lines.
    ///
    /// Layout (looking at the pad):
    ///           Y
    ///        X     A
    ///           B
    private static func diamondABXY(size: CGFloat = 60) -> [Item] {
        // The diamond fits in a 3×3 grid of `size`-cells anchored to the bottom-right corner.
        // Column 0 = right-inset (rightmost = A), column 2 = leftmost (X). Y sits on top,
        // B sits on bottom.
        let cellW = size + 12  // horizontal spacing between diamond points
        let cellH = size + 12
        let rightInset: CGFloat = 20
        let bottomInset: CGFloat = 70
        return [
            // A — right point
            Item(role: .a, anchor: .bottomRight, offset: CGPoint(x: rightInset,               y: bottomInset + cellH),     size: CGSize(width: size, height: size), shape: .roundedSquare(cornerRadius: 8), extendedEdges: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)),
            // X — left point
            Item(role: .x, anchor: .bottomRight, offset: CGPoint(x: rightInset + cellW * 2,   y: bottomInset + cellH),     size: CGSize(width: size, height: size), shape: .roundedSquare(cornerRadius: 8), extendedEdges: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)),
            // Y — top point
            Item(role: .y, anchor: .bottomRight, offset: CGPoint(x: rightInset + cellW,       y: bottomInset + cellH * 2), size: CGSize(width: size, height: size), shape: .roundedSquare(cornerRadius: 8), extendedEdges: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)),
            // B — bottom point
            Item(role: .b, anchor: .bottomRight, offset: CGPoint(x: rightInset + cellW,       y: bottomInset),             size: CGSize(width: size, height: size), shape: .roundedSquare(cornerRadius: 8), extendedEdges: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)),
        ]
    }

    /// Long pill Select/Start centered on the bottom edge.
    private static func pillSelectStart() -> [Item] {
        return [
            Item(role: .select, anchor: .bottomCenter, offset: CGPoint(x: -43, y: 12), size: CGSize(width: 74, height: 28), shape: .pill, extendedEdges: UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)),
            Item(role: .start,  anchor: .bottomCenter, offset: CGPoint(x:  43, y: 12), size: CGSize(width: 74, height: 28), shape: .pill, extendedEdges: UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)),
        ]
    }

    /// Small rectangle Select/Start (the tiny black rectangular US NES pad look).
    private static func rectSelectStart() -> [Item] {
        return [
            Item(role: .select, anchor: .bottomCenter, offset: CGPoint(x: -36, y: 12), size: CGSize(width: 60, height: 20), shape: .rectangle, extendedEdges: UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)),
            Item(role: .start,  anchor: .bottomCenter, offset: CGPoint(x:  36, y: 12), size: CGSize(width: 60, height: 20), shape: .rectangle, extendedEdges: UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)),
        ]
    }

    private static let defaultMapping = CGSize(width: 414, height: 260)

    // MARK: - Catalog

    /// Every theme available in the picker. First entry is the default when nothing is stored.
    static let all: [GamepadTheme] = [
        // Classic Cross — the baseline 4-arrow D-pad + round A/B (small size).
        GamepadTheme(
            id: .classicCross,
            displayName: "经典十字键",
            style: .flat,
            colors: Colors(
                idleBackground: UIColor(white: 0.18, alpha: 1.0),
                pressedBackground: UIColor(red: 0.86, green: 0.11, blue: 0.16, alpha: 1.0),
                border: UIColor(white: 0.05, alpha: 1.0),
                text: .white
            ),
            mappingSize: defaultMapping,
            items: separatedDpad(size: 50) + horizontalAB(size: 64) + rectSelectStart()
        ),

        // Analog Stick — one-piece round drag stick on the left, medium round A/B on the right.
        // The stick view emits 8-way events via drag; see AnalogStickView.
        GamepadTheme(
            id: .analogStick,
            displayName: "虚拟摇杆",
            style: .raised,
            colors: Colors(
                idleBackground: UIColor(white: 0.22, alpha: 1.0),
                pressedBackground: UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1.0),
                border: UIColor(white: 0.08, alpha: 1.0),
                text: .white
            ),
            mappingSize: defaultMapping,
            items: analogStick(diameter: 160) + horizontalAB(size: 68) + pillSelectStart()
        ),

        // Disc Pad — one-piece octagonal 8-way pad on the left (diagonals fire two arrows at
        // once), medium round A/B on the right. Feels like a PlayStation D-pad.
        GamepadTheme(
            id: .discPad,
            displayName: "圆盘 8 向",
            style: .flat,
            colors: Colors(
                idleBackground: UIColor(white: 0.16, alpha: 1.0),
                pressedBackground: UIColor(red: 0.95, green: 0.60, blue: 0.15, alpha: 1.0),
                border: UIColor(white: 0.05, alpha: 1.0),
                text: .white
            ),
            mappingSize: defaultMapping,
            items: discPad(diameter: 160) + horizontalAB(size: 64) + rectSelectStart()
        ),

        // Arcade Diamond — SNES-style A/B/X/Y diamond on the right (X→A, Y→B), big separated
        // D-pad on the left. Bigger buttons overall — this is the "large size" preset.
        GamepadTheme(
            id: .arcadeDiamond,
            displayName: "街机四键",
            style: .raised,
            colors: Colors(
                idleBackground: UIColor(red: 0.14, green: 0.09, blue: 0.22, alpha: 1.0),
                pressedBackground: UIColor(red: 0.95, green: 0.20, blue: 0.75, alpha: 1.0),
                border: UIColor(red: 0.15, green: 0.90, blue: 0.95, alpha: 1.0),
                text: .white
            ),
            mappingSize: defaultMapping,
            items: separatedDpad(size: 58) + diamondABXY(size: 60) + pillSelectStart()
        ),
    ]

    /// Look up a theme by its persisted ID. Falls back to the first entry if unknown.
    static func theme(for id: ID) -> GamepadTheme {
        return all.first(where: { $0.id == id }) ?? all[0]
    }
}
