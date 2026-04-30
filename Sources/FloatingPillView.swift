// Sources/FloatingPillView.swift
// Magpie — Floating recording pill.
//
// Raven icon | pulsing dot | mm:ss | stop (or spinner when transcribing)

import AppKit
import SwiftUI

struct FloatingPillView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 8) {
            ravenIcon
            pulsingDot
            timerLabel
            if model.isTranscribing {
                ProgressView()
                    .controlSize(.small)
            } else {
                stopButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Magpie recording, \(model.elapsedSeconds / 60)m \(model.elapsedSeconds % 60)s")
        .accessibilityAddTraits(.isHeader)
    }

    private var ravenIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "raven", withExtension: "svg"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var pulsingDot: some View {
        Circle()
            .fill(MagpieColors.recordingRed)
            .frame(width: 7, height: 7)
            .opacity(model.isRecording ? 1.0 : 0.3)
            .animation(
                model.isRecording
                    ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                    : .default,
                value: model.isRecording
            )
    }

    private var timerLabel: some View {
        let m = model.elapsedSeconds / 60
        let s = model.elapsedSeconds % 60
        return Text(String(format: "%02d:%02d", m, s))
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(.primary)
    }

    private var stopButton: some View {
        Button(action: { model.stopRecording() }) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(MagpieColors.recordingRed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}
