// Sources/FloatingPillView.swift
// Magpie — Floating pill with three render modes, redesigned per the
// Calendar Surfaces spec.
//
//   .recording             — paper-white pill, sandstone pulse + stop.
//   .idlePrompt            — pale-sky pill with calendar prompt + countdown.
//   .recordingWithDrawer   — paper-white head + pale-sky drawer body.
//
// Resilience notes (issue #9 was an invisible-pill regression on Tahoe):
//   - One background layer per pill (Material below, tinted fill above), no
//     nested .background → .overlay chains. The previous PillChassis stacked
//     ultraThinMaterial + tint + clipShape + two strokeBorder overlays + two
//     shadows; that combination tripped _NSDetectedLayoutRecursion on Tahoe.
//   - No GeometryReader-driven measurement loops. Long meeting titles
//     truncate with a tail ellipsis instead of marquee-scrolling. The
//     marquee can come back later as a separate, isolated component.
//   - The SwiftUI root fills the window via `.frame(maxWidth: .infinity,
//     maxHeight: .infinity)`; the pill itself is overlay-anchored to the
//     top-left so window height changes (drawer reveal) don't relayout
//     the pill chassis.

import AppKit
import SwiftUI

// MARK: - Root

struct FloatingPillView: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        // Root view is structurally stable: always renders a pill (never
        // EmptyView). Window-level orderOut handles "truly hidden". The
        // EmptyView ↔ content swap on first paint was the recursion source
        // — issue #13 bisected the regression to cd9d0b3 and called this
        // out as the cleanest delta to revert.
        pill
            .frame(width: 320, alignment: .topLeading)
            .opacity(model.pillMode == .hidden ? 0 : 1)
    }

    @ViewBuilder
    private var pill: some View {
        switch model.pillMode {
        case .hidden, .recording:
            RecordingPill()
        case .idlePrompt:
            if let prompt = model.pendingPrompt {
                IdlePromptPill(prompt: prompt)
            } else {
                RecordingPill()
            }
        case .recordingWithDrawer:
            if let prompt = model.pendingPrompt {
                RecordingDrawerPill(prompt: prompt)
            } else {
                RecordingPill()
            }
        }
    }
}

// MARK: - Tokens

private enum PillToken {
    static let sansMedium12 = Font.custom("Inter", size: 12).weight(.medium)
    static let sansMedium12_5 = Font.custom("Inter", size: 12.5).weight(.medium)
    static let mono12_5 = Font.system(size: 12.5, weight: .medium, design: .monospaced)
    static let serifItalic11 = Font.custom("Lora", size: 11)

    static let eggshellTint = MagpieColors.eggshell.opacity(0.82)
    static let paleSkyTint = MagpieColors.paleSky.opacity(0.88)
    static let recordingBorder = MagpieColors.slate.opacity(0.35)
    static let promptBorder = MagpieColors.slate.opacity(0.55)
    static let dividerColor = MagpieColors.slate.opacity(0.32)
}

// MARK: - Brand mark

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

// MARK: - Pulsing record dot

private struct RecordingDot: View {
    // Pulse via TimelineView, NOT .onAppear { withAnimation.repeatForever }.
    // TimelineView re-renders its body off SwiftUI's render clock; the
    // invalidation stays inside the timeline subtree and doesn't propagate
    // back through the hosting view's measurement loop, so it doesn't fire
    // _NSDetectedLayoutRecursion the way the previous repeatForever
    // animation did (issue #13). Throttled to 30Hz — plenty smooth for a
    // pulse, half the work of display-refresh.
    //
    // Visual matches the design's CSS keyframes:
    //   dot opacity:  1.0 → 0.55 → 1.0
    //   ring stroke:  scale 1.0 → 1.75, opacity 0.28 → 0
    // both phased on a 1.6s sine.
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6  // 0..1
            let s = sin(phase * .pi)                                  // 0..1..0
            let dotOpacity = 1.0 - 0.45 * s
            let ringScale = 1.0 + 0.75 * s
            let ringOpacity = 0.28 * (1 - s)

            Circle()
                .fill(MagpieColors.sandstone)
                .frame(width: 8, height: 8)
                .opacity(dotOpacity)
                .overlay(
                    Circle()
                        .stroke(MagpieColors.sandstone.opacity(ringOpacity),
                                lineWidth: 1.5)
                        .scaleEffect(ringScale)
                )
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Stop button

private struct StopButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear.frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MagpieColors.sandstone)
                    .frame(width: 9, height: 9)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}

// MARK: - Compact equalizer (reads model.audioLevel)

private struct PillEqualizer: View {
    let level: Float

    @State private var tick: Double = 0
    private let timer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()
    private let phaseOffsets: [Double] = [0.0, 1.1, 2.3, 0.7, 1.8, 2.7, 0.4]
    private let restingHeights: [CGFloat] = [0.35, 0.70, 1.00, 0.55, 0.80, 0.40, 0.25]
    private static let maxHeight: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                Capsule()
                    .fill(MagpieColors.plumCharcoal.opacity(0.85))
                    .frame(width: 2, height: barHeight(i))
                    .animation(.easeOut(duration: 0.10), value: tick)
            }
        }
        .frame(width: 22, height: Self.maxHeight)
        .onReceive(timer) { _ in
            if level > 0.01 { tick += 1 }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard level > 0.01 else { return restingHeights[index] * Self.maxHeight }
        let wave = sin(tick * 0.4 + phaseOffsets[index]) * 0.35 + 0.65
        return max(2, min(CGFloat(level) * Self.maxHeight * wave, Self.maxHeight))
    }
}

// MARK: - Mono timer

private struct MonoTimer: View {
    let seconds: Int

    var body: some View {
        let m = seconds / 60
        let s = seconds % 60
        Text(String(format: "%02d:%02d", m, s))
            .font(PillToken.mono12_5)
            .monospacedDigit()
            .foregroundColor(MagpieColors.darkPlum)
            .tracking(0.2)
    }
}

// MARK: - Single-layer pill background

/// One Material layer + one tinted fill + one stroke + one shadow. No nested
/// overlays. This is the structure that keeps Tahoe from triggering the
/// layout-recursion guard.
private struct PillBackground: View {
    let tint: Color
    let border: Color
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            )
            .shadow(color: Color(red: 20/255, green: 12/255, blue: 35/255).opacity(0.22),
                    radius: 14, x: 0, y: 6)
    }
}

// MARK: - 1 · Recording pill

private struct RecordingPill: View {
    @EnvironmentObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 9) {
            RavenGlyph()
            RecordingDot()
            MonoTimer(seconds: model.elapsedSeconds)
            PillEqualizer(level: model.audioLevel)
            StopButton { model.stopRecording() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(
            PillBackground(tint: PillToken.eggshellTint,
                           border: PillToken.recordingBorder,
                           cornerRadius: 18)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Magpie recording, \(model.elapsedSeconds / 60)m \(model.elapsedSeconds % 60)s")
    }
}

// MARK: - 2 · Idle prompt pill

private struct IdlePromptPill: View {
    @EnvironmentObject var model: RecorderModel
    let prompt: CalendarPrompt

    @State private var remaining: Double = 1.0
    @State private var countdownStart: Date? = nil
    @State private var countdownTimer: Timer? = nil
    private let dismissAfter: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(MagpieColors.darkPlum)

                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.event.title)
                        .font(PillToken.sansMedium12_5)
                        .foregroundColor(MagpieColors.darkPlum)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("starts at \(prompt.startTimeLabel)")
                        .font(PillToken.serifItalic11)
                        .italic()
                        .foregroundColor(MagpieColors.slateText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Skip") { dismiss() }
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
            .padding(.vertical, 4)

            CountdownBar(remaining: remaining)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
        .frame(width: 320, height: 44)
        .background(
            PillBackground(tint: PillToken.paleSkyTint,
                           border: PillToken.promptBorder,
                           cornerRadius: 22)
        )
        .onAppear { startCountdown() }
        .onDisappear { stopCountdown() }
    }

    private func record() {
        let title = prompt.event.title
        model.pendingPrompt = nil
        model.startRecording(title: title)
    }

    private func dismiss() {
        model.pendingPrompt = nil
    }

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

private struct RecordingDrawerPill: View {
    @EnvironmentObject var model: RecorderModel
    let prompt: CalendarPrompt

    var body: some View {
        VStack(spacing: 0) {
            // Head — same content vocabulary as RecordingPill, no chassis.
            HStack(spacing: 10) {
                RavenGlyph()
                RecordingDot()
                MonoTimer(seconds: model.elapsedSeconds)
                PillEqualizer(level: model.audioLevel)
                Spacer(minLength: 0)
                StopButton { model.stopRecording() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 10)

            Rectangle()
                .fill(PillToken.dividerColor)
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            // Drawer body — pale-sky tint over the whole pill's chassis.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(MagpieColors.darkPlum)
                    Text("End current recording and start next?")
                        .font(PillToken.sansMedium12)
                        .foregroundColor(MagpieColors.darkPlum)
                }

                Text("\(prompt.event.title) · \(prompt.startTimeLabel)")
                    .font(PillToken.serifItalic11)
                    .italic()
                    .foregroundColor(MagpieColors.slateText)
                    .lineLimit(2)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MagpieColors.paleSky.opacity(0.55))
        }
        .frame(width: 320)
        .background(
            PillBackground(tint: PillToken.eggshellTint,
                           border: PillToken.recordingBorder,
                           cornerRadius: 20)
        )
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

// MARK: - Buttons

private struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PillToken.sansMedium12)
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
            .font(PillToken.sansMedium12)
            .foregroundColor(configuration.isPressed ? MagpieColors.darkPlum : MagpieColors.slateText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Capsule())
    }
}

// MARK: - Countdown bar

private struct CountdownBar: View {
    let remaining: Double  // 1.0 → 0

    // Idle prompt pill is fixed-width 320pt with 14pt horizontal inset on
    // both sides. Hard-coding the width here so we don't need a
    // GeometryReader inside the pill — measurement-in-layout is one of the
    // recursion patterns issue #11 called out.
    private static let totalWidth: CGFloat = 320 - 28

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(MagpieColors.slate.opacity(0.10))
                .frame(width: Self.totalWidth, height: 1)
            Capsule()
                .fill(MagpieColors.sandstone.opacity(0.85))
                .frame(width: Self.totalWidth * CGFloat(remaining), height: 1)
        }
        .frame(width: Self.totalWidth, height: 1)
    }
}
