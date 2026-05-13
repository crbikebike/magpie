// Sources/FloatingPillView.swift
// Magpie — Floating pill with three render modes:
//   .recording             — paper-white frosted pill, sandstone pulse + stop.
//   .idlePrompt            — pale-sky frosted pill with calendar prompt + countdown.
//   .recordingWithDrawer   — recording head + pale-sky drawer for "next meeting?".
//
// All visual tokens come from MagpieColors / the Magpie design system. The pill
// background uses .ultraThinMaterial with a tinted overlay; shadows are layered
// to approximate the design system's frosted-glass spec.

import AppKit
import SwiftUI

// MARK: - Root

struct FloatingPillView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        Group {
            switch model.pillMode {
            case .hidden:
                EmptyView()
            case .recording:
                RecordingPill()
            case .idlePrompt:
                if let prompt = model.pendingPrompt {
                    IdlePromptPill(prompt: prompt)
                }
            case .recordingWithDrawer:
                if let prompt = model.pendingPrompt {
                    RecordingWithDrawerPill(prompt: prompt)
                }
            }
        }
        // Smooth transitions between modes — drawer reveal / collapse.
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.pillMode)
    }
}

// MARK: - Shared chrome

/// Capsule chassis used by both recording + prompt pills. Renders the
/// design system's "frosted glass" — material blur + tinted overlay +
/// hairline border + soft drop shadow + inner highlight.
private struct PillChassis<Content: View>: View {
    let surface: SurfaceTint
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    enum SurfaceTint {
        case paperWhite     // recording pill (eggshell over blur)
        case paleSky        // idle prompt pill (calendar tint over blur)
    }

    var body: some View {
        content()
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    surfaceFill
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                // Hairline border + inner highlight overlay
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 0.5)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
            )
            // Layered shadows — soft + ambient.
            .shadow(color: Color(red: 20/255, green: 12/255, blue: 35/255).opacity(0.22),
                    radius: 30, x: 0, y: 10)
            .shadow(color: Color(red: 20/255, green: 12/255, blue: 35/255).opacity(0.10),
                    radius: 2, x: 0, y: 1)
    }

    private var surfaceFill: Color {
        switch surface {
        case .paperWhite: return MagpieColors.eggshell.opacity(0.78)
        case .paleSky:    return MagpieColors.paleSky.opacity(0.86)
        }
    }
    private var borderColor: Color {
        switch surface {
        case .paperWhite: return MagpieColors.slate.opacity(0.35)
        case .paleSky:    return MagpieColors.slate.opacity(0.55)
        }
    }
}

// MARK: - Raven mark

/// 14pt raven SVG used as the left-edge brand glyph on the recording pill.
private struct RavenGlyph: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "raven", withExtension: "svg"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(MagpieColors.darkPlum.opacity(0.85))
                    .frame(width: 14, height: 14)
            }
        }
    }
}

// MARK: - Sandstone pulse dot

private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(MagpieColors.sandstone)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(MagpieColors.sandstone.opacity(pulse ? 0 : 0.28), lineWidth: pulse ? 6 : 2)
                    .scaleEffect(pulse ? 1.8 : 1.0)
            )
            .opacity(pulse ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse.toggle()
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Sandstone stop button (square)

private struct StopSquareButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear.frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(MagpieColors.sandstone)
                    .frame(width: 9, height: 9)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}

// MARK: - Compact 7-bar equalizer (re-uses audio level)

private struct CompactEqualizer: View {
    let level: Float

    private let phaseOffsets: [Double] = [0.0, 1.1, 2.3, 0.7, 1.8, 2.7, 0.4]
    @State private var tick: Double = 0
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private static let maxHeight: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(MagpieColors.plumCharcoal.opacity(0.85))
                    .frame(width: 2, height: barHeight(i))
                    .animation(.easeOut(duration: 0.08), value: tick)
            }
        }
        .frame(width: 22, height: Self.maxHeight)
        .onReceive(timer) { _ in
            if level > 0.01 { tick += 1 }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // Quiet idle state — 25% baseline using design's static heights.
        let resting: [CGFloat] = [0.35, 0.70, 1.00, 0.55, 0.80, 0.40, 0.25]
        guard level > 0.01 else { return resting[index] * Self.maxHeight }
        let wave = sin(tick * 0.4 + phaseOffsets[index]) * 0.35 + 0.65
        return max(2, min(CGFloat(level) * Self.maxHeight * wave, Self.maxHeight))
    }
}

// MARK: - Mono timer label

private struct MonoTimer: View {
    let seconds: Int

    var body: some View {
        let m = seconds / 60
        let s = seconds % 60
        Text(String(format: "%02d:%02d", m, s))
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(MagpieColors.darkPlum)
            .tracking(0.2)
    }
}

// MARK: - 1 · Recording pill

private struct RecordingPill: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        PillChassis(surface: .paperWhite, cornerRadius: 18) {
            HStack(spacing: 9) {
                RavenGlyph()
                RecordingDot()
                MonoTimer(seconds: model.elapsedSeconds)
                CompactEqualizer(level: model.audioLevel)
                StopSquareButton { model.stopRecording() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Magpie recording, \(model.elapsedSeconds / 60)m \(model.elapsedSeconds % 60)s")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 2 · Idle prompt pill

private struct IdlePromptPill: View {
    @EnvironmentObject var model: RecorderModel
    let prompt: CalendarPrompt

    /// Auto-dismiss countdown. 1.0 → 0 over 30s. Drives the hairline bar
    /// at the bottom and triggers dismissal when it reaches zero.
    @State private var remaining: Double = 1.0
    private let dismissAfter: Double = 30

    var body: some View {
        PillChassis(surface: .paleSky, cornerRadius: 22) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    CalendarGlyph(size: 16)
                        .foregroundColor(MagpieColors.darkPlum)

                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: prompt.event.title,
                                    font: .system(size: 12.5, weight: .medium),
                                    color: MagpieColors.darkPlum,
                                    maxWidth: 170)

                        Text("starts at \(prompt.startTimeLabel)")
                            .font(.custom("Lora", size: 11, relativeTo: .footnote))
                            .italic()
                            .foregroundColor(MagpieColors.slateText)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Skip") {
                        dismiss()
                    }
                    .buttonStyle(QuietPillButtonStyle())

                    Button(action: record) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(MagpieColors.onSandstone)
                                .frame(width: 6, height: 6)
                            Text("Record")
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.top, 4)

                CountdownBar(remaining: remaining)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .padding(.top, 2)
            }
            .frame(height: 44)
            .frame(maxWidth: 320)
        }
        .onAppear { startCountdown() }
        .onDisappear { stopCountdown() }
    }

    private func record() {
        let title = prompt.event.title
        model.pendingPrompt = nil
        model.startRecording(title: title)
    }

    private func dismiss() {
        // MeetingScheduler.fireAlert already inserted this event into its
        // alertedEventIDs set when it set the prompt, so clearing the prompt
        // here is enough — the next 15-min refresh won't re-schedule it.
        model.pendingPrompt = nil
    }

    @State private var countdownStart: Date? = nil
    @State private var countdownTimer: Timer? = nil

    private func startCountdown() {
        countdownStart = Date()
        remaining = 1.0
        countdownTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            guard let start = countdownStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            let r = max(0, 1.0 - elapsed / dismissAfter)
            DispatchQueue.main.async {
                remaining = r
                if r <= 0 {
                    t.invalidate()
                    dismiss()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}

// MARK: - 3 · Recording with drawer

private struct RecordingWithDrawerPill: View {
    @EnvironmentObject var model: RecorderModel
    let prompt: CalendarPrompt

    var body: some View {
        VStack(spacing: 0) {
            // Head — looks like the recording pill, embedded in the larger container.
            HStack(spacing: 9) {
                RavenGlyph()
                RecordingDot()
                MonoTimer(seconds: model.elapsedSeconds)
                CompactEqualizer(level: model.audioLevel)
                Spacer(minLength: 0)
                StopSquareButton { model.stopRecording() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 10)

            // Hairline divider.
            Rectangle()
                .fill(MagpieColors.slate.opacity(0.35))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            // Drawer — pale-sky gradient body.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CalendarGlyph(size: 16)
                        .foregroundColor(MagpieColors.darkPlum)
                    Text("End current recording and start next?")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MagpieColors.darkPlum)
                }

                Text("\(prompt.event.title) · \(prompt.startTimeLabel)")
                    .font(.custom("Lora", size: 11, relativeTo: .footnote))
                    .italic()
                    .foregroundColor(MagpieColors.slateText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Button(action: recordNext) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(MagpieColors.onSandstone)
                                .frame(width: 6, height: 6)
                            Text("Record next meeting")
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())

                    Button("Skip") { skipDrawer() }
                        .buttonStyle(QuietPillButtonStyle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: MagpieColors.paleSky.opacity(0.0), location: 0.0),
                        .init(color: MagpieColors.paleSky.opacity(0.55), location: 0.3),
                        .init(color: MagpieColors.paleSky.opacity(0.75), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .frame(width: 320)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                MagpieColors.eggshell.opacity(0.78)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(MagpieColors.slate.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: Color(red: 20/255, green: 12/255, blue: 35/255).opacity(0.28),
                radius: 36, x: 0, y: 12)
        .shadow(color: Color(red: 20/255, green: 12/255, blue: 35/255).opacity(0.12),
                radius: 3, x: 0, y: 1)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func recordNext() {
        let title = prompt.event.title
        model.pendingPrompt = nil
        model.stopAndStart(title: title)
    }

    private func skipDrawer() {
        model.pendingPrompt = nil
    }
}

// MARK: - Button styles

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(MagpieColors.onSandstone)
            .padding(.leading, 11)
            .padding(.trailing, 13)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(MagpieColors.sandstone)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
    }
}

private struct QuietPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(configuration.isPressed ? MagpieColors.darkPlum : MagpieColors.slateText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.clear))
    }
}

// MARK: - Countdown bar

private struct CountdownBar: View {
    let remaining: Double  // 1.0 → 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MagpieColors.slate.opacity(0.10))
                    .frame(height: 1)
                Capsule()
                    .fill(MagpieColors.sandstone.opacity(0.85))
                    .frame(width: geo.size.width * CGFloat(remaining), height: 1)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 1)
    }
}

// MARK: - Calendar glyph

private struct CalendarGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "calendar")
            .font(.system(size: size, weight: .regular))
    }
}

// MARK: - Marquee text

/// Single-line text. If its intrinsic width exceeds `maxWidth` the text
/// holds for 2s, slides left to reveal the tail, holds at the end for 2s,
/// then slides back. Total cycle ≈ 9s. Respects reduce-motion.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let maxWidth: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationCycle: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat {
        max(0, textWidth - maxWidth + 12)
    }
    private var shouldScroll: Bool { overflow > 0 && !reduceMotion }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .background(
                GeometryReader { textGeo in
                    Color.clear
                        .onAppear { textWidth = textGeo.size.width }
                        .onChange(of: textGeo.size.width) { _, w in textWidth = w }
                }
            )
            .frame(width: maxWidth, height: 16, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: shouldScroll ? 0.92 : 1.0),
                        .init(color: shouldScroll ? .clear : .black, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .onAppear {
                animationCycle += 1
                scheduleCycle(generation: animationCycle)
            }
            .onChange(of: text) { _, _ in
                offset = 0
                animationCycle += 1
                scheduleCycle(generation: animationCycle)
            }
    }

    private func scheduleCycle(generation: Int) {
        guard shouldScroll else { offset = 0; return }
        // 2s hold, 2s slide left, 2s hold at tail, 2s slide back, 1s breathe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard generation == animationCycle else { return }
            withAnimation(.easeInOut(duration: 2)) { offset = -overflow }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard generation == animationCycle else { return }
                withAnimation(.easeInOut(duration: 2)) { offset = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    scheduleCycle(generation: generation)
                }
            }
        }
    }
}
