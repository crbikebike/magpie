// Sources/RecorderView.swift
// Magpie — Main popover UI.
//
// All three audio modes are now selectable. System audio modes are gated on
// sysAudioPermission — unauthorized taps open onboarding.

import AppKit
import SwiftUI

private let consentReminderColor = MagpieColors.pencil

struct RecorderView: View {
    @EnvironmentObject var model: RecorderModel
    @State private var showHeadphoneNudge = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            contentArea
            Divider()
            footerRow
        }
        .frame(width: 300)
        .onAppear {
            if model.vaultPath == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    model.pickVault()
                }
            }
            // Headphone nudge — delegate to model.needsHeadphoneNudge so the guard
            // logic (dismissed flag, UserDefaults sentinel, mode check, live
            // headphone state) lives in one place rather than two.
            showHeadphoneNudge = model.needsHeadphoneNudge
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRecording ? MagpieColors.recordingRed : MagpieColors.pencil.opacity(0.4))
                .frame(width: 8, height: 8)
            Text("Magpie")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode picker — only shown when idle
            if !model.isRecording {
                // Headphone nudge banner (one-time)
                if showHeadphoneNudge {
                    headphoneNudgeBanner
                }
                audioModeSection
            }

            consentReminderLabel

            actionArea

            systemAudioBanner

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Post-first-recording confirmation banner
            if model.showFirstRecordingConfirmation {
                Text("✅ Full audio captured — both sides of the call.")
                    .font(.caption)
                    .foregroundColor(MagpieColors.successGreen)
                    .transition(.opacity)
            }

            if !model.recentTranscripts.isEmpty {
                recentTranscriptsList
            }

            if model.vaultPath != nil {
                Divider()
                watcherStatusRow
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
    }

    // MARK: - Audio Mode Section

    private var audioModeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Audio source:")
                .font(.caption)
                .foregroundColor(MagpieColors.pencil)

            ForEach(AudioMode.allCases) { mode in
                audioModeRow(mode)
            }
        }
    }

    @ViewBuilder
    private func audioModeRow(_ mode: AudioMode) -> some View {
        let isSelected = model.audioMode == mode
        let requiresSysAudio = mode == .systemOnly || mode == .micAndSystem
        let sysAudioAvailable = model.sysAudioPermission == .authorized
        let isAvailable = !requiresSysAudio || sysAudioAvailable

        Button {
            if isAvailable {
                model.audioMode = mode
            } else {
                model.showOnboarding = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color.accentColor : MagpieColors.pencil.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(mode.rawValue)
                    .font(.callout)
                    .foregroundColor(isSelected ? .primary : (isAvailable ? .primary : MagpieColors.pencil))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                } else if !isAvailable {
                    Text("setup required")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(MagpieColors.pencil.opacity(0.1))
                        .cornerRadius(3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Headphone Nudge Banner

    private var headphoneNudgeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Headphones detected")
                .font(.caption).fontWeight(.medium)
            Text("Switch to Mic + System to capture both sides of your calls.")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button("Switch") {
                    model.audioMode = .micAndSystem
                    UserDefaults.standard.set(true, forKey: "headphone_nudge_shown")
                    model.headphoneNudgeDismissed = true
                    withAnimation { showHeadphoneNudge = false }
                }
                .font(.caption).buttonStyle(.borderedProminent)
                Button("Not now") {
                    UserDefaults.standard.set(true, forKey: "headphone_nudge_shown")
                    model.headphoneNudgeDismissed = true
                    withAnimation { showHeadphoneNudge = false }
                }
                .font(.caption).buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
        .padding(.horizontal, 4)
    }

    // MARK: - System Audio Banner

    @ViewBuilder
    private var systemAudioBanner: some View {
        switch model.systemAudioStatus {
        case .unavailable(let reason):
            switch reason {
            case .permissionDenied:
                bannerView(
                    text: "System audio permission needed",
                    color: MagpieColors.warningAmber,
                    action: ("Open Settings", {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                )
            case .generic:
                bannerView(
                    text: "System audio unavailable — recording mic only",
                    color: MagpieColors.warningAmber,
                    action: nil
                )
            case .coreaudiodStall:
                // In .systemOnly mode there is no mic, so the message must not
                // reference it. Use a mode-aware string.
                let stallText = model.audioMode == .systemOnly
                    ? "System audio interrupted — attempting to reconnect"
                    : "System audio interrupted — mic still recording"
                bannerView(
                    text: stallText,
                    color: MagpieColors.warningAmber,
                    action: nil
                )
            }
        case .interrupted:
            // TODO: AVAudioSession interruption wiring not yet implemented — this
            // case is forward-scaffolded and is never emitted in the current build.
            // See ADR-031 for the planned AVAudioSession notification hook.
            bannerView(
                text: "System audio interrupted — mic still recording",
                color: MagpieColors.warningAmber,
                action: nil
            )
        case .reconnected:
            // TODO: .reconnected is also forward-scaffolded; no code path emits it yet.
            // Will be wired alongside AVAudioSession interruption handling (ADR-031).
            bannerView(text: "System audio reconnected", color: MagpieColors.successGreen, action: nil)
        case .micUnavailable:
            bannerView(
                text: "Can't start recording — another app (like Zoom) may be controlling the microphone. Try again after your call ends.",
                color: MagpieColors.warningAmber,
                action: nil
            )
        case .active, .notApplicable:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bannerView(
        text: String,
        color: Color,
        action: (String, () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.caption).fontWeight(.medium)
            if let (buttonLabel, buttonAction) = action {
                Button(buttonLabel, action: buttonAction)
                    .font(.caption).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    // MARK: - Consent Reminder

    private var consentReminderLabel: some View {
        Text("Remind others you're recording")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(consentReminderColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Reminder: tell others you are recording")
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        if model.isRecording {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(MagpieColors.recordingRed)
                        .frame(width: 8, height: 8)
                    Text(formattedElapsed)
                        .font(.callout.monospacedDigit())
                    Spacer()
                    EqualizerView(level: model.audioLevel)
                }
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MagpieColors.recordingRed)
            }

        } else {
            Button {
                model.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(MagpieColors.recordingRed)
            .disabled(model.vaultPath == nil)
        }

        // Transcription status shown below the action button, non-blocking
        if model.isTranscribing {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Transcribing \(model.activeTranscriptions) recording\(model.activeTranscriptions == 1 ? "" : "s")…")
                    .font(.caption)
                    .foregroundColor(MagpieColors.pencil)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Recent Transcripts

    private var recentTranscriptsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent:")
                .font(.caption)
                .foregroundColor(MagpieColors.pencil)
            ForEach(model.recentTranscripts, id: \.self) { url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("• \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Watcher Status Row

    private var watcherStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isWatcherRunning ? MagpieColors.successGreen : MagpieColors.warningAmber)
                .frame(width: 8, height: 8)
            Text("Watcher")
                .font(.caption)
                .foregroundColor(MagpieColors.pencil)
            Text(model.isWatcherRunning ? "running" : "stopped")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(model.isWatcherRunning ? "Stop" : "Start") {
                model.toggleWatcher()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Output:")
                    .font(.caption2)
                    .foregroundColor(MagpieColors.pencil)
                if let vault = model.vaultPath {
                    Text(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .lineLimit(2)
                } else {
                    Text("Not configured")
                        .font(.caption)
                        .foregroundColor(MagpieColors.warningAmber)
                }
            }
            Spacer()
            Button("Change") { model.pickVault() }
                .font(.caption)
                .buttonStyle(.plain)
            Button("Quit") { NSApp.terminate(nil) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(MagpieColors.pencil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        String(format: "%02d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
    }
}
