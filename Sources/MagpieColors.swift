// Sources/MagpieColors.swift
// Magpie — Brand color tokens for the macOS recorder UI.
// Light mode only; dark mode deferred per brand-guide-v1.md.

import SwiftUI

enum MagpieColors {
    /// Brick red — recording/stop/risk signal. Brand: health-red (#a85a4a).
    static let recordingRed = Color(red: 168 / 255, green: 90 / 255, blue: 74 / 255)
    /// Muted sage green — success/authorized signal. Brand: health-green (#5a8a5a).
    static let successGreen = Color(red: 90 / 255, green: 138 / 255, blue: 90 / 255)
    /// Warm amber — warning/stale signal. Brand: amber-nudge (#c4883a).
    static let warningAmber = Color(red: 196 / 255, green: 136 / 255, blue: 58 / 255)
    /// Dark gray — secondary text. Brand: graphite (#4a4a4a).
    static let graphite = Color(red: 74 / 255, green: 74 / 255, blue: 74 / 255)
    /// Medium gray — tertiary text, disabled states. Brand: pencil (#8a8a8a).
    static let pencil = Color(red: 138 / 255, green: 138 / 255, blue: 138 / 255)
}
