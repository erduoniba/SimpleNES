//
//  GamepadTheme.swift
//  HDSimpleNES
//
//  Skin definitions for the on-screen touch controls, modeled after Delta's overlay format
//  in miniature. A theme is a flat **items[] array** authored in a reference `mappingSize`
//  coordinate space; TouchGamepadView scales and anchor-places each item at layout time.
//
//  Why the model looks like this (vs the previous "three blocks with per-block enums"):
//    - Freedom of arrangement — Famicom vs Arcade vs Dogbone don't share a common skeleton.
//      Each Item is independent (role, anchor, offset, size, shape, extendedEdges).
//    - Extendable — dropping in another button (turbo? R?), a decorative label, a shape-only
//      element (unified D-pad cross) is one array append per theme.
//    - Sizes stay in POINTS (not normalized 0-1). `mappingSize` gates ONLY the min-scale
//      down-shrink for narrow devices; on same-or-larger bounds items keep their authored
//      point sizes and are anchor-placed. That matches how the current fixed-size buttons
//      already feel in portrait, and prevents them from ballooning in landscape overlay.
//
//  Two axes still stack on top of items:
//    - `style` — visual treatment (flat / raised / neon / pixel / glass). Cross-cuts colors.
//    - `colors` — 4-color palette (idle bg, pressed bg, border, text).
//
//  Applied at two places (same as before):
//    1. TouchGamepadView.applyTheme(_:) — tears the view hierarchy down and rebuilds from
//       items[]. Cheap: a handful of frames, no images.
//    2. Prefs.setSelectedTheme(_:) — persists the choice by ID.
//

import UIKit

/// A single controller skin: items[] + visual style + colors. See file header.
struct GamepadTheme {

    /// Stable string ID for UserDefaults storage. Adding a theme: extend this enum + `all`.
    enum ID: String, CaseIterable {
        case classicNES    = "classic-nes"
        case famicom       = "famicom"
        case dogbone       = "nes-dogbone"
        case arcadeNeon    = "arcade-neon"
        case pixelRetro    = "pixel-retro"
        case ghostGlass    = "ghost-glass"
    }

    /// Visual treatment. Controls border weight, shadow, gradient overlay, and (for glass) blur.
    enum Style {
        /// Flat solid fill with a thin 1pt border.
        case flat
        /// 3D-raised: gradient highlight + drop shadow, buttons look physically pressable.
        case raised
        /// Bright glowing halo around the button (layer shadow with 0 offset + large blur).
        case neon
        /// Chunky 3pt border, zero corner radius. Reads as 8-bit UI.
        case pixel
        /// Frosted glass — semi-transparent fill + UIVisualEffectView blur behind.
        case glass
    }

    /// The four colors every style honors (with per-style interpretation — e.g. `border`
    /// becomes the glow color for `.neon`).
    struct Colors {
        let idleBackground: UIColor
        let pressedBackground: UIColor
        let border: UIColor
        let text: UIColor
    }

    /// Which conceptual button (or non-interactive element) an Item represents. TouchGamepadView
    /// switches on this to decide (a) whether to wire it to the NES input line, (b) what label
    /// glyph to draw, (c) whether to draw the special plus-shape backing.
    enum Role {
        case dpadUp, dpadDown, dpadLeft, dpadRight
        /// Non-interactive plus-shape drawn UNDER the four dpad arrow items — makes the four
        /// separated arrows read as one unified cross rocker (十字键). Only present in themes
        /// that want the classic-NES look; separated-dpad themes omit it entirely.
        case dpadCrossBacking
        case a, b, select, start
        /// A pure decoration item — no input, just paints its label with the text color and
        /// the given shape. Used for things like a "Nintendo" wordmark strip.
        case decoration(String)
    }

    /// Which corner of the bounds an item's `offset` is measured from. `offset.y` grows
    /// AWAY from the anchor's horizontal edge — so `.bottomLeft` with offset (20, 55) means
    /// 20pt from the left, 55pt UP from the bottom.
    enum Anchor {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        /// Anchored to the bottom-center; `offset.x` is signed distance from center (negative
        /// = left), `offset.y` is upward from the bottom edge.
        case bottomCenter
        case topCenter
    }

    /// Geometric shape of an item's fill area. Corner radius derives from this + the theme's
    /// style (pixel forces 0 across the board).
    enum Shape {
        /// D-pad direction key — small rounded square (6pt corner).
        case dpadArrow
        /// Perfect circle — corner radius = min(w,h)/2. Classic NES A/B.
        case circle
        /// Rounded square with the given corner radius. `0` produces a hard square.
        case roundedSquare(cornerRadius: CGFloat)
        /// Long capsule — corner radius = height/2. Pill Select/Start.
        case pill
        /// Small rectangle with a 3pt corner. Tiny black NES Select/Start.
        case rectangle
        /// The unified plus-shape backing of a cross D-pad. TouchGamepadView renders this via
        /// CAShapeLayer rather than as a UIControl. Not meant for interactive roles.
        case plusCross
    }

    /// One placed element in a theme's layout.
    struct Item {
        let role: Role
        let anchor: Anchor
        /// Offset from the anchor corner, in `mappingSize` point units. See `Anchor` for how
        /// the axis directions flip per corner.
        let offset: CGPoint
        /// Item size, in `mappingSize` point units.
        let size: CGSize
        let shape: Shape
        /// How far outside the visible frame the hit area should extend. Positive values grow
        /// the touch region (matches Delta's `extendedEdges`). Applied uniformly across the
        /// four sides; scaled with the item on smaller devices.
        let extendedEdges: UIEdgeInsets
    }

    let id: ID
    /// User-facing label in the picker sheet.
    let displayName: String
    let style: Style
    let colors: Colors
    /// The reference coordinate space the items[] were authored in. If the actual gamepad
    /// bounds are SMALLER than this on either axis, TouchGamepadView down-scales items
    /// uniformly; if they're larger the items keep their authored point size (only anchor
    /// placement changes with bounds). 414×260 = a comfortable iPhone-portrait mapping.
    let mappingSize: CGSize
    let items: [Item]

    // MARK: - Item factories
    //
    // Concrete item coordinates for the reusable building blocks. Themes pick a set,
    // concatenate them, and pass them as `items`. Numbers were chosen to reproduce the
    // pre-refactor autolayout: dpad 150×150 anchored bottom-left with 20pt inset and a
    // 55pt bottom margin; A/B 64×64 anchored bottom-right with matching insets; select/start
    // centered along the bottom.

    /// 150×150 unified-cross D-pad in the bottom-left corner (classic NES look).
    private static func crossDpad() -> [Item] {
        return [
            Item(role: .dpadCrossBacking, anchor: .bottomLeft, offset: CGPoint(x: 20,  y: 55),  size: CGSize(width: 150, height: 150), shape: .plusCross,  extendedEdges: .zero),
            Item(role: .dpadUp,           anchor: .bottomLeft, offset: CGPoint(x: 70,  y: 155), size: CGSize(width: 50,  height: 50),  shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)),
            Item(role: .dpadDown,         anchor: .bottomLeft, offset: CGPoint(x: 70,  y: 55),  size: CGSize(width: 50,  height: 50),  shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)),
            Item(role: .dpadLeft,         anchor: .bottomLeft, offset: CGPoint(x: 20,  y: 105), size: CGSize(width: 50,  height: 50),  shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 0)),
            Item(role: .dpadRight,        anchor: .bottomLeft, offset: CGPoint(x: 120, y: 105), size: CGSize(width: 50,  height: 50),  shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 8)),
        ]
    }

    /// 4 separated arrow blocks in the bottom-left corner (arcade / pixel look — no plus behind).
    private static func separatedDpad() -> [Item] {
        return [
            Item(role: .dpadUp,    anchor: .bottomLeft, offset: CGPoint(x: 70,  y: 155), size: CGSize(width: 50, height: 50), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)),
            Item(role: .dpadDown,  anchor: .bottomLeft, offset: CGPoint(x: 70,  y: 55),  size: CGSize(width: 50, height: 50), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)),
            Item(role: .dpadLeft,  anchor: .bottomLeft, offset: CGPoint(x: 20,  y: 105), size: CGSize(width: 50, height: 50), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 0)),
            Item(role: .dpadRight, anchor: .bottomLeft, offset: CGPoint(x: 120, y: 105), size: CGSize(width: 50, height: 50), shape: .dpadArrow, extendedEdges: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 8)),
        ]
    }

    /// A/B side-by-side horizontally (B on the left, A on the right), 64pt buttons.
    private static func horizontalAB(shape: Shape) -> [Item] {
        return [
            Item(role: .b, anchor: .bottomRight, offset: CGPoint(x: 104, y: 98), size: CGSize(width: 64, height: 64), shape: shape, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
            Item(role: .a, anchor: .bottomRight, offset: CGPoint(x: 20,  y: 98), size: CGSize(width: 64, height: 64), shape: shape, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
        ]
    }

    /// A/B diagonally offset (B lower-left, A upper-right). Preserves the ~22° slope that
    /// matches the NES Dogbone and later SNES pad conventions.
    private static func diagonalAB(shape: Shape) -> [Item] {
        return [
            Item(role: .b, anchor: .bottomRight, offset: CGPoint(x: 104, y: 86),  size: CGSize(width: 64, height: 64), shape: shape, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
            Item(role: .a, anchor: .bottomRight, offset: CGPoint(x: 20,  y: 110), size: CGSize(width: 64, height: 64), shape: shape, extendedEdges: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)),
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

    /// Same reference mapping across every stock theme. If a bespoke theme needs a wider
    /// authoring canvas (e.g. it pins a decoration at x=500), that theme can override.
    private static let defaultMapping = CGSize(width: 414, height: 260)

    // MARK: - Catalog

    /// Every theme available in the picker. First entry is the default when nothing is stored.
    static let all: [GamepadTheme] = [
        // Classic NES — the iconic US "brick" pad: gray body, unified cross D-pad (十字键),
        // two red round A/B side by side, small rectangular black Select/Start.
        GamepadTheme(
            id: .classicNES,
            displayName: "经典 NES",
            style: .flat,
            colors: Colors(
                idleBackground: UIColor(white: 0.18, alpha: 1.0),
                pressedBackground: UIColor(red: 0.86, green: 0.11, blue: 0.16, alpha: 1.0),
                border: UIColor(white: 0.05, alpha: 1.0),
                text: .white
            ),
            mappingSize: defaultMapping,
            items: crossDpad() + horizontalAB(shape: .circle) + rectSelectStart()
        ),

        // Famicom (红白机) — the Japanese original: cream body with bright red A/B, red pill
        // Select/Start.
        GamepadTheme(
            id: .famicom,
            displayName: "红白机",
            style: .raised,
            colors: Colors(
                idleBackground: UIColor(red: 0.94, green: 0.88, blue: 0.75, alpha: 1.0),
                pressedBackground: UIColor(red: 0.82, green: 0.13, blue: 0.15, alpha: 1.0),
                border: UIColor(red: 0.60, green: 0.10, blue: 0.10, alpha: 1.0),
                text: UIColor(red: 0.40, green: 0.08, blue: 0.08, alpha: 1.0)
            ),
            mappingSize: defaultMapping,
            items: crossDpad() + horizontalAB(shape: .circle) + pillSelectStart()
        ),

        // NES Dogbone — the curved NES-101 top-loader pad. Cross D-pad + diagonal A/B (the
        // early "dogbone" curve that later evolved into the SNES layout).
        GamepadTheme(
            id: .dogbone,
            displayName: "NES 圆润",
            style: .raised,
            colors: Colors(
                idleBackground: UIColor(white: 0.85, alpha: 1.0),
                pressedBackground: UIColor(red: 0.55, green: 0.15, blue: 0.85, alpha: 1.0),
                border: UIColor(white: 0.35, alpha: 1.0),
                text: UIColor(white: 0.10, alpha: 1.0)
            ),
            mappingSize: defaultMapping,
            items: crossDpad() + diagonalAB(shape: .circle) + rectSelectStart()
        ),

        // Arcade Neon — cabinet aesthetic: neon-glowing action buttons on a plain 4-block
        // D-pad (arcade sticks don't have a cross rocker). Big pill Select/Start = credit/start.
        GamepadTheme(
            id: .arcadeNeon,
            displayName: "街机霓虹",
            style: .neon,
            colors: Colors(
                idleBackground: UIColor(red: 0.10, green: 0.05, blue: 0.20, alpha: 1.0),
                pressedBackground: UIColor(red: 0.95, green: 0.20, blue: 0.75, alpha: 1.0),
                border: UIColor(red: 0.15, green: 0.90, blue: 0.95, alpha: 1.0),
                text: UIColor(red: 0.30, green: 0.95, blue: 0.95, alpha: 1.0)
            ),
            mappingSize: defaultMapping,
            items: separatedDpad() + horizontalAB(shape: .circle) + pillSelectStart()
        ),

        // Pixel Retro — 8-bit UI: chunky 3pt border, zero corner radius, square A/B, rect S/S.
        // The `.pixel` style forces radius = 0 regardless of shape, so we still declare
        // `.roundedSquare(0)` for clarity.
        GamepadTheme(
            id: .pixelRetro,
            displayName: "像素",
            style: .pixel,
            colors: Colors(
                idleBackground: UIColor(red: 0.13, green: 0.24, blue: 0.45, alpha: 1.0),
                pressedBackground: UIColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 1.0),
                border: UIColor(white: 1.0, alpha: 1.0),
                text: UIColor(white: 1.0, alpha: 1.0)
            ),
            mappingSize: defaultMapping,
            items: separatedDpad() + horizontalAB(shape: .roundedSquare(cornerRadius: 0)) + rectSelectStart()
        ),

        // Ghost Glass — frosted-blur buttons designed for landscape overlay. Simple separated
        // D-pad so as little as possible obscures the picture.
        GamepadTheme(
            id: .ghostGlass,
            displayName: "透明",
            style: .glass,
            colors: Colors(
                idleBackground: UIColor(white: 1.0, alpha: 0.14),
                pressedBackground: UIColor(white: 1.0, alpha: 0.55),
                border: UIColor(white: 1.0, alpha: 0.45),
                text: UIColor(white: 1.0, alpha: 0.95)
            ),
            mappingSize: defaultMapping,
            items: separatedDpad() + horizontalAB(shape: .circle) + pillSelectStart()
        ),
    ]

    /// Look up a theme by its persisted ID. Falls back to the first entry if unknown.
    static func theme(for id: ID) -> GamepadTheme {
        return all.first(where: { $0.id == id }) ?? all[0]
    }
}
