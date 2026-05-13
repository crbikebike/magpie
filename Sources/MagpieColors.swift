// Sources/MagpieColors.swift
// Magpie — Brand color tokens from the design system.
// Light mode only; dark mode deferred per brand-guide-v1.md.

import SwiftUI

enum MagpieColors {
    // MARK: - Cool tonal ramp (surfaces & structure)

    /// Pale sky — active surface tint, calendar-prompt pill surface. #cae5ff
    static let paleSky = Color(hex: 0xCAE5FF)
    /// Periwinkle — quantity badges, count indicators, default calendar swatch. #89bbfe
    static let periwinkle = Color(hex: 0x89BBFE)
    /// Slate — dividers, hairlines, decorative blue. #6f8ab7
    static let slate = Color(hex: 0x6F8AB7)
    /// Slate text — secondary text, metadata. #4c5760
    static let slateText = Color(hex: 0x4C5760)
    /// Plum charcoal — tertiary labels, italic verdicts. #615d6c
    static let plumCharcoal = Color(hex: 0x615D6C)

    // MARK: - Body anchor

    /// Dark plum — body text, titles. #2c2935
    static let darkPlum = Color(hex: 0x2C2935)

    // MARK: - Page surfaces

    /// Eggshell — page background. #faf6ec
    static let eggshell = Color(hex: 0xFAF6EC)
    /// Paper white — topic / done-check card surface. #ffffff
    static let paperWhite = Color(hex: 0xFFFFFF)

    // MARK: - Earth accents (used sparingly)

    /// Sage — ongoing / on-track / authorized signal. #87b38d
    static let sage = Color(hex: 0x87B38D)
    /// Sandstone — primary action moments only (record button, pulsing dot). #B0533A
    static let sandstone = Color(hex: 0xB0533A)

    // MARK: - Derived tints (quiet status pills)

    static let sageTintBg = Color(hex: 0xE6F0E8)
    static let sageTintFg = Color(hex: 0x4A7D5E)
    static let sandstoneTintBg = Color(hex: 0xF0D4C8)
    static let sandstoneTintFg = Color(hex: 0x7E3823)

    // MARK: - Special pairings

    /// Cream text on sandstone-filled buttons. #faf6ec
    static let onSandstone = Color(hex: 0xFAF6EC)
    /// Dark blue text for periwinkle badges. #1a3866
    static let badgeFg = Color(hex: 0x1A3866)

    // MARK: - Status accents

    /// Amber — "needs attention" / failure dot. #ffa62b
    static let amber = Color(hex: 0xFFA62B)
    /// Amber text on warning chips. #8a4f00
    static let amberText = Color(hex: 0x8A4F00)
    /// Soft amber tint behind warning chips. (rgba(255,166,43,0.16) flattened)
    static let amberTintBg = Color(red: 255 / 255, green: 166 / 255, blue: 43 / 255, opacity: 0.16)

    // MARK: - Semantic aliases (covers all prior call-sites)

    /// Primary action / recording (was `recordingRed` — now sandstone).
    static let recordingRed = sandstone
    /// Success signal (was `successGreen` — now sage).
    static let successGreen = sage
    /// Warning signal (was `warningAmber` — now amber).
    static let warningAmber = amber
    /// Secondary text (was `graphite` — now slate text).
    static let graphite = slateText
    /// Tertiary text (was `pencil` — now plum charcoal).
    static let pencil = plumCharcoal
}

// MARK: - Color hex initializer

extension Color {
    /// Initialize from a 0xRRGGBB hex literal.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
