// Sources/EqualizerView.swift
// Aperture — Animated 5-bar equalizer visualisation.
//
// Driven by a Float level (0..1) sourced from AudioLevelMonitor.
// Bars animate independently via sine-wave phase offsets.

import SwiftUI

struct EqualizerView: View {
    let level: Float

    private let barCount = 5
    private let maxHeight: CGFloat = 18
    private let minHeight: CGFloat = 2
    private let phaseOffsets: [Double] = [0.0, 1.1, 2.3, 0.7, 1.8]

    @State private var tick: Double = 0
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: i))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeOut(duration: 0.08), value: tick)
            }
        }
        .frame(width: 23, height: maxHeight, alignment: .bottom)
        .onReceive(timer) { _ in
            if level > 0.01 { tick += 1 }
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        guard level > 0.01 else { return minHeight }
        let wave = sin(tick * 0.4 + phaseOffsets[index]) * 0.35 + 0.65
        return max(minHeight, min(CGFloat(level) * maxHeight * wave, maxHeight))
    }

    private func barColor(index: Int) -> Color {
        let dist = abs(index - barCount / 2)
        return MagpieColors.recordingRed.opacity(1.0 - Double(dist) * 0.2)
    }
}
