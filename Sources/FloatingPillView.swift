// Sources/FloatingPillView.swift
// Magpie — SwiftUI content for the floating recording pill.
//
// Compact horizontal capsule with pulsing red dot, elapsed time,
// audio level bars (reuses EqualizerView), and stop button.

import SwiftUI

struct FloatingPillView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 10) {
            pulsingDot
            elapsedLabel

            EqualizerView(level: model.audioLevel)
                .frame(width: 23, height: 18)

            if model.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MagpieColors.pencil)
            } else {
                stopButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Magpie recording in progress, \(model.elapsedSeconds) seconds")
        .accessibilityAddTraits(.isHeader)
        .help("Others should know you're recording")
    }

    // Oscillates opacity 0.3↔1.0 while recording via repeatForever.
    // When isRecording flips to true, SwiftUI animates between the prior
    // opacity (0.3) and current (1.0) with a 1s ease-in-out cycle.
    private var pulsingDot: some View {
        Circle()
            .fill(MagpieColors.recordingRed)
            .frame(width: 8, height: 8)
            .opacity(model.isRecording ? 1.0 : 0.3)
            .animation(
                model.isRecording
                    ? Animation.easeInOut(duration: 1).repeatForever(autoreverses: true)
                    : .default,
                value: model.isRecording
            )
    }

    private var elapsedLabel: some View {
        let minutes = model.elapsedSeconds / 60
        let seconds = model.elapsedSeconds % 60
        return Text(String(format: "%02d:%02d", minutes, seconds))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(.primary)
    }

    private var stopButton: some View {
        Button(action: { model.stopRecording() }) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(MagpieColors.recordingRed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}
