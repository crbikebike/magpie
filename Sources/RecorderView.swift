// Sources/RecorderView.swift
// Magpie — Menubar popover, redesigned per the Calendar Surfaces spec
// (Section 6 · Menubar popover). 320pt eggshell card, blocks separated by
// hairlines, Watcher + Calendar share one toggle pattern.
//
// Behavior preservation: every state branch from the prior implementation
// is retained — recording / transcribing / saved / status messages /
// system-audio failures / headphone nudge / vault-not-configured.

import AppKit
import SwiftUI

// MARK: - Tokens

private enum PopToken {
    static let sansMedium10  = Font.custom("Inter", size: 10).weight(.medium)
    static let sansMedium11  = Font.custom("Inter", size: 11).weight(.medium)
    static let sansMedium12  = Font.custom("Inter", size: 12).weight(.medium)
    static let sansMedium12_5 = Font.custom("Inter", size: 12.5).weight(.medium)
    static let sansMedium13  = Font.custom("Inter", size: 13).weight(.medium)
    static let serifItalic11 = Font.custom("Lora", size: 11)
    static let serifItalic11_5 = Font.custom("Lora", size: 11.5)
    static let mono11        = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let mono11_5      = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    static let mono12_5      = Font.system(size: 12.5, weight: .medium, design: .monospaced)

    static let hairline      = MagpieColors.paleSky          // --border-quiet
    static let footerWash    = MagpieColors.paleSky.opacity(0.18)
    static let radioHover    = MagpieColors.slate.opacity(0.10)
    static let recentHover   = MagpieColors.slate.opacity(0.12)
    static let toggleOff     = MagpieColors.slate.opacity(0.32)
}

// MARK: - Raven glyph (popover-private)

private struct PopRavenGlyph: View {
    var size: CGFloat = 14
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "raven", withExtension: "svg"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(MagpieColors.darkPlum)
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - Hairline divider matching --border-quiet

private struct PopDivider: View {
    var body: some View {
        Rectangle()
            .fill(PopToken.hairline)
            .frame(height: 0.5)
    }
}

// MARK: - Section heading

private struct PopSectionHead: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(PopToken.sansMedium10)
            .tracking(0.6)
            .foregroundColor(MagpieColors.slateText)
    }
}

// MARK: - Primary "Start/Stop Recording" button — design's .mb-record-btn

private struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PopToken.sansMedium13)
            .foregroundColor(MagpieColors.onSandstone)
            .tracking(0.1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MagpieColors.sandstone)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: MagpieColors.sandstone.opacity(0.18), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Toggle style — design's .mb-toggle (30×17 track, sandstone when on)

private struct MbToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? MagpieColors.sandstone : PopToken.toggleOff)
                    .frame(width: 30, height: 17)
                Circle()
                    .fill(MagpieColors.paperWhite)
                    .frame(width: 14, height: 14)
                    .padding(1.5)
                    .shadow(color: Color.black.opacity(0.20), radius: 1, x: 0, y: 1)
            }
            .animation(.easeInOut(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tinted banner used for nudges + system-audio failures + saved row

private struct PopBanner<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint)
            )
    }
}

// MARK: - Audio-source radio row — design's .mb-radio

private struct AudioRadioRow: View {
    let mode: AudioMode
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? MagpieColors.sandstone : MagpieColors.slate,
                            lineWidth: 1
                        )
                        .background(Circle().fill(MagpieColors.paperWhite))
                        .frame(width: 13, height: 13)
                    if isSelected {
                        Circle()
                            .fill(MagpieColors.sandstone)
                            .frame(width: 7, height: 7)
                    }
                }
                Text(mode.rawValue)
                    .font(PopToken.sansMedium12_5)
                    .foregroundColor(isAvailable ? MagpieColors.darkPlum : MagpieColors.plumCharcoal)
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(MagpieColors.sandstone)
                } else if !isAvailable {
                    Text("setup required")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(MagpieColors.plumCharcoal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(MagpieColors.plumCharcoal.opacity(0.10))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? PopToken.radioHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Watcher / Calendar toggle row — design's .mb-row

private struct ToggleStatusRow: View {
    let icon: String
    let label: String
    let status: String
    let statusOn: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(MagpieColors.slateText)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(PopToken.sansMedium12_5)
                    .foregroundColor(MagpieColors.darkPlum)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusOn ? MagpieColors.sage : MagpieColors.slate)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(PopToken.serifItalic11)
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(MbToggleStyle())
        }
        .frame(minHeight: 30)
        .padding(.vertical, 6)
    }
}

// MARK: - Recent transcript row — design's .mb-recent a

private struct RecentRow: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(url.lastPathComponent)
                .font(PopToken.mono11_5)
                .foregroundColor(MagpieColors.periwinkle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? PopToken.recentHover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Footer link button — design's .mb-link

private struct FooterLink: View {
    let label: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(PopToken.sansMedium12)
                .foregroundColor(hovering ? MagpieColors.darkPlum : color)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Content-height preference

/// Bubbles the popover's natural content height up to the AppDelegate so the
/// NSPopover can resize to fit. Measured via a GeometryReader in `.background`
/// — a passive, read-only pass that does NOT feed AppKit/SwiftUI's layout
/// recursion path the way `sizingOptions = [.preferredContentSize]` does
/// (issues #4, #6, #11).
struct PopoverContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Root

struct RecorderView: View {
    @EnvironmentObject var model: RecorderModel
    @State private var showHeadphoneNudge = false
    @AppStorage("calendarAlertsEnabled") private var calendarAlertsEnabled: Bool = false

    /// Fires with the popover's natural content height on every layout pass.
    /// The AppDelegate consumes this to size the NSPopover.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            PopDivider()
            audioBlock
            if !model.recentTranscripts.isEmpty {
                PopDivider()
                recentBlock
            }
            if model.vaultPath != nil {
                PopDivider()
                togglesBlock
            }
            PopDivider()
            footer
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(MagpieColors.eggshell)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: PopoverContentHeight.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(PopoverContentHeight.self) { h in
            onHeightChange?(h)
        }
        .onAppear {
            if model.vaultPath == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    model.pickVault()
                }
            }
            showHeadphoneNudge = model.needsHeadphoneNudge
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            PopRavenGlyph(size: 14)
                .frame(width: 18, height: 18)
            Text("Magpie")
                .font(PopToken.sansMedium13)
                .foregroundColor(MagpieColors.darkPlum)
            Spacer()
            if model.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MagpieColors.sandstone)
                        .frame(width: 6, height: 6)
                    Text("recording")
                        .font(PopToken.serifItalic11)
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Audio source block (radios + nudge + disclaimer + button + transcribing + banners + saved)

    private var audioBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.isRecording {
                PopSectionHead(text: "Audio source")
                radiosGroup
                if showHeadphoneNudge {
                    headphoneNudgeBanner
                }
            }

            // Disclaimer sits above the primary action, even while recording —
            // a steady reminder of the consent norm.
            Text("Remember to tell others you're recording.")
                .font(PopToken.serifItalic11_5)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            primaryActionButton

            if model.isRecording {
                recordingMetaRow
            }

            if model.isTranscribing {
                transcribingRow
            }

            systemAudioBanner

            // First-recording green confirmation, restyled in the design system.
            if model.showFirstRecordingConfirmation {
                PopBanner(tint: MagpieColors.sage.opacity(0.16)) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(MagpieColors.sage)
                            .frame(width: 6, height: 6)
                        Text("Full audio captured — both sides of the call.")
                            .font(.system(size: 12))
                            .foregroundColor(MagpieColors.sageTintFg)
                    }
                }
            }

            // statusMessage: render as the design's "Saved" row when prefixed,
            // else as a subtle slate caption (carries error strings today).
            if !model.statusMessage.isEmpty {
                if let saved = savedFilename {
                    savedRow(filename: saved)
                } else {
                    Text(model.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(MagpieColors.slateText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var radiosGroup: some View {
        VStack(spacing: 0) {
            ForEach(AudioMode.allCases) { mode in
                let isSelected = model.audioMode == mode
                let requiresSysAudio = mode == .systemOnly || mode == .micAndSystem
                let sysAudioAvailable = model.sysAudioPermission == .authorized
                let isAvailable = !requiresSysAudio || sysAudioAvailable
                AudioRadioRow(
                    mode: mode,
                    isSelected: isSelected,
                    isAvailable: isAvailable
                ) {
                    if isAvailable {
                        model.audioMode = mode
                    } else {
                        model.showOnboarding = true
                    }
                }
            }
        }
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
    }

    private var headphoneNudgeBanner: some View {
        PopBanner(tint: MagpieColors.paleSky.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Headphones detected")
                    .font(PopToken.sansMedium12)
                    .foregroundColor(MagpieColors.darkPlum)
                Text("Switch to Mic + System to capture both sides of your calls.")
                    .font(.system(size: 11))
                    .foregroundColor(MagpieColors.slateText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Switch") {
                        model.audioMode = .micAndSystem
                        UserDefaults.standard.set(true, forKey: "headphone_nudge_shown")
                        model.headphoneNudgeDismissed = true
                        withAnimation { showHeadphoneNudge = false }
                    }
                    .buttonStyle(SmallSandstoneButtonStyle())

                    Button("Not now") {
                        UserDefaults.standard.set(true, forKey: "headphone_nudge_shown")
                        model.headphoneNudgeDismissed = true
                        withAnimation { showHeadphoneNudge = false }
                    }
                    .buttonStyle(QuietLinkButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if model.isRecording {
            Button {
                model.stopRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 14, weight: .regular))
                    Text("Stop Recording")
                }
            }
            .buttonStyle(RecordButtonStyle())
        } else {
            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(MagpieColors.onSandstone, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    Text("Start Recording")
                }
            }
            .buttonStyle(RecordButtonStyle())
            .disabled(model.vaultPath == nil)
        }
    }

    private var recordingMetaRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(MagpieColors.sandstone)
                .frame(width: 7, height: 7)
            Text(formattedElapsed)
                .font(PopToken.mono12_5)
                .foregroundColor(MagpieColors.darkPlum)
                .monospacedDigit()
            Spacer()
            EqualizerView(level: model.audioLevel)
        }
        .padding(.horizontal, 2)
    }

    private var transcribingRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(MagpieColors.sage)
                .frame(width: 6, height: 6)
            Text("transcribing \(model.activeTranscriptions) recording\(model.activeTranscriptions == 1 ? "" : "s")…")
                .font(PopToken.serifItalic11)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var systemAudioBanner: some View {
        switch model.systemAudioStatus {
        case .unavailable(let reason):
            switch reason {
            case .permissionDenied:
                amberBanner(
                    text: "System audio permission needed",
                    cta: ("Open Settings", {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                )
            case .generic:
                amberBanner(text: "System audio unavailable — recording mic only", cta: nil)
            case .coreaudiodStall:
                let stallText = model.audioMode == .systemOnly
                    ? "System audio interrupted — attempting to reconnect"
                    : "System audio interrupted — mic still recording"
                amberBanner(text: stallText, cta: nil)
            }
        case .interrupted:
            amberBanner(text: "System audio interrupted — mic still recording", cta: nil)
        case .reconnected:
            PopBanner(tint: MagpieColors.sage.opacity(0.16)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(MagpieColors.sage)
                        .frame(width: 6, height: 6)
                    Text("System audio reconnected")
                        .font(.system(size: 12))
                        .foregroundColor(MagpieColors.sageTintFg)
                }
            }
        case .micUnavailable:
            amberBanner(
                text: "Can't start recording — another app (like Zoom) may be controlling the microphone. Try again after your call ends.",
                cta: nil
            )
        case .active, .notApplicable:
            EmptyView()
        }
    }

    @ViewBuilder
    private func amberBanner(text: String, cta: (String, () -> Void)?) -> some View {
        PopBanner(tint: MagpieColors.amberTintBg) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(MagpieColors.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                if let (label, action) = cta {
                    Button(label, action: action)
                        .buttonStyle(SmallSandstoneButtonStyle())
                }
            }
        }
    }

    /// The model's `statusMessage` carries "Saved: <filename>" on completion.
    /// Surface that as the design's saved row using the actual recent-transcript
    /// filename when available, otherwise the suffix of the message.
    private var savedFilename: String? {
        let msg = model.statusMessage
        guard msg.hasPrefix("Saved") else { return nil }
        if let url = model.recentTranscripts.first {
            return url.lastPathComponent
        }
        if let colonIdx = msg.firstIndex(of: ":") {
            return String(msg[msg.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return msg
    }

    private func savedRow(filename: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Saved")
                .font(PopToken.serifItalic11_5)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
            Text(filename)
                .font(PopToken.mono11)
                .foregroundColor(MagpieColors.slateText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    // MARK: Recent block

    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopSectionHead(text: "Recent")
            VStack(spacing: 2) {
                ForEach(model.recentTranscripts, id: \.self) { url in
                    RecentRow(url: url)
                }
            }
            .padding(.horizontal, -6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: Toggles block (Watcher + Calendar)

    private var togglesBlock: some View {
        VStack(spacing: 6) {
            ToggleStatusRow(
                icon: "eye",
                label: "Watcher",
                status: model.isWatcherRunning ? "running" : "paused",
                statusOn: model.isWatcherRunning,
                isOn: Binding(
                    get: { model.isWatcherRunning },
                    set: { desired in
                        if desired != model.isWatcherRunning {
                            model.toggleWatcher()
                        }
                    }
                )
            )
            ToggleStatusRow(
                icon: "calendar",
                label: "Calendar",
                status: calendarAlertsEnabled ? "on" : "off",
                statusOn: calendarAlertsEnabled,
                isOn: $calendarAlertsEnabled
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Output")
                    .font(PopToken.serifItalic11)
                    .italic()
                    .foregroundColor(MagpieColors.plumCharcoal)
                if let vault = model.vaultPath {
                    Text(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(PopToken.mono11)
                        .foregroundColor(MagpieColors.slateText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not configured")
                        .font(PopToken.mono11)
                        .foregroundColor(MagpieColors.amber)
                }
            }
            Spacer(minLength: 8)
            FooterLink(label: "Change", color: MagpieColors.slateText) {
                model.pickVault()
            }
            Rectangle()
                .fill(PopToken.hairline)
                .frame(width: 1, height: 11)
            FooterLink(label: "Quit", color: MagpieColors.plumCharcoal) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: PopToken.footerWash, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        String(format: "%02d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
    }
}

// MARK: - Small button styles used by banners

private struct SmallSandstoneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(MagpieColors.onSandstone)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(MagpieColors.sandstone)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
    }
}

private struct QuietLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(configuration.isPressed ? MagpieColors.darkPlum : MagpieColors.slateText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Capsule())
    }
}
