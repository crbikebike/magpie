// Sources/OnboardingView.swift
// Magpie — First-run permissions and vault setup.

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Calendar onboarding state

/// Outcome of probing the Claude Code Google Calendar connector.
enum CalendarOnboardingBranch: Equatable {
    case probing                                // initial — show spinner
    case signedOut                              // user not signed in to Claude Code
    case notAuthorized(hint: String)            // signed in, connector not authorized yet
    case ready                                  // probe returned events (or empty list)
    case probeError(detail: String)             // generic failure (network, timeout, etc.)
}

// MARK: - View

struct OnboardingView: View {
    @EnvironmentObject var model: RecorderModel
    let calendarService: CalendarService
    var onDone: (() -> Void)? = nil

    @State private var calendarBranch: CalendarOnboardingBranch
    @State private var probeTask: Task<Void, Never>? = nil
    @State private var calendarSetupRequested = false

    init(calendarService: CalendarService = CalendarService(), onDone: (() -> Void)? = nil) {
        self.calendarService = calendarService
        self.onDone = onDone
        // Returning users (alerts previously enabled) see the Done badge; new
        // users see the Set up button. Either way we do NOT auto-probe on
        // appear — a probe spawns `claude`, which can trigger TCC dialogs for
        // whatever the spawned process or its shell wrapper happens to touch.
        let alreadyEnabled = UserDefaults.standard.bool(forKey: CalendarPrefs.alertsEnabled)
        _calendarBranch = State(initialValue: alreadyEnabled ? .ready : .signedOut)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Magpie")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(MagpieColors.darkPlum)
                    Text("Set up permissions so your recordings capture what you need")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

            // Output folder row
            vaultRow

            Divider()

            // Mic permission card
            permissionCard(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Record your voice",
                status: cardStatus(model.micPermission),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                action: { model.requestMicPermission() }
            )

            // System audio card — macOS 14.2+ only
            if #available(macOS 14.2, *) {
                Divider()
                permissionCard(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    detail: "Capture both sides of Zoom, Meet, and Teams calls",
                    status: sysAudioCardStatus,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    deniedDetailText: "Can't access system audio yet",
                    action: { model.requestSysAudioPermission() }
                )
            }

            Divider()

            calendarAlertsCard

            Divider()

                // Done button — requires vault + mic; system audio + calendar optional
                VStack(spacing: 8) {
                    Button {
                        model.showOnboarding = false
                        model.refreshPermissions()
                        onDone?()
                    } label: {
                        Text("Done")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MagpieColors.sandstone)
                    .disabled(model.vaultPath == nil || model.micPermission != .authorized)

                    Button {
                        model.showOnboarding = false
                    } label: {
                        Text("Close")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
            }
            .frame(width: 320)
        }
        .frame(width: 320)
        .onDisappear { probeTask?.cancel() }
    }

    // MARK: - System Audio Card Status

    private var sysAudioCardStatus: CardStatus {
        switch model.sysAudioPermission {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        }
    }

    // MARK: - Vault Row

    private var vaultRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundColor(model.vaultPath != nil ? MagpieColors.sage : MagpieColors.plumCharcoal)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Output Folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MagpieColors.darkPlum)
                if let vault = model.vaultPath {
                    Text(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.custom("Lora", size: 12))
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                        .lineLimit(2)
                } else {
                    Text("Not configured")
                        .font(.custom("Lora", size: 12))
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                }
            }

            Spacer()

            if model.vaultPath != nil {
                doneTag
            } else {
                Button("Choose") { model.pickVault() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .tint(MagpieColors.sandstone)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Permission Card

    private enum CardStatus { case notDetermined, authorized, denied }

    private func cardStatus(_ auth: AVAuthorizationStatus) -> CardStatus {
        switch auth {
        case .authorized:    return .authorized
        case .denied:        return .denied
        default:             return .notDetermined
        }
    }

    @ViewBuilder
    private func permissionCard(
        icon: String,
        title: String,
        detail: String,
        status: CardStatus,
        settingsURL: String,
        deniedDetailText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(status == .authorized ? MagpieColors.sage : MagpieColors.plumCharcoal)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MagpieColors.darkPlum)
                Text(detail)
                    .font(.custom("Lora", size: 12))
                    .italic()
                    .foregroundColor(MagpieColors.plumCharcoal)
            }

            Spacer()

            switch status {
            case .authorized:
                doneTag
            case .denied:
                VStack(alignment: .trailing, spacing: 2) {
                    if let detailText = deniedDetailText {
                        Text(detailText)
                            .font(.system(size: 11))
                            .foregroundColor(MagpieColors.amberText)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: settingsURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
                }
            case .notDetermined:
                Button("Enable") { action() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .tint(MagpieColors.sandstone)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Calendar Alerts Card

    @ViewBuilder
    private var calendarAlertsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "calendar")
                    .font(.title2)
                    .foregroundColor(calendarIconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar alerts")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(MagpieColors.darkPlum)
                    Text(calendarDetailText)
                        .font(.custom("Lora", size: 12))
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                }

                Spacer()

                switch calendarBranch {
                case .ready:
                    doneTag
                case .probing:
                    ProgressView().scaleEffect(0.6)
                case .signedOut, .notAuthorized, .probeError:
                    if !calendarSetupRequested {
                        Button("Set up") {
                            calendarSetupRequested = true
                            runProbe()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.borderedProminent)
                        .tint(MagpieColors.sandstone)
                    }
                }
            }

            if calendarSetupRequested {
                switch calendarBranch {
                case .signedOut:
                    signedOutBranch
                case .notAuthorized:
                    notAuthorizedBranch
                case .probeError(let detail):
                    probeErrorBranch(detail: detail)
                case .probing, .ready:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var calendarIconColor: Color {
        switch calendarBranch {
        case .ready:              return MagpieColors.sage
        case .signedOut,
             .notAuthorized,
             .probeError:         return MagpieColors.amber
        case .probing:            return MagpieColors.plumCharcoal
        }
    }

    private var calendarDetailText: String {
        switch calendarBranch {
        case .ready:              return "Prompting you 30 seconds before each meeting"
        case .signedOut:          return "Reads your calendar through Claude Code · optional"
        case .notAuthorized:      return "Signed in · one more grant to finish"
        case .probeError:         return "Reads your calendar through Claude Code · optional"
        case .probing:            return "Checking your Claude Code setup…"
        }
    }

    @ViewBuilder
    private var signedOutBranch: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusChip(tone: .amber, text: "Not signed in to Claude Code")
            Text("Magpie asks Claude Code to read your calendar — so events stay on your machine and Magpie never sees your Google credentials.")
                .font(.system(size: 12))
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(2)

            HStack(spacing: 8) {
                Button("Open Terminal") {
                    openTerminalWithLoginHint()
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderedProminent)
                .tint(MagpieColors.sandstone)

                Button("Re-check") { runProbe() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
            }

            Text("Run `claude /login` in your terminal, then click Re-check.")
                .font(.custom("Lora", size: 11.5))
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
        }
        .padding(.leading, 40)
    }

    @ViewBuilder
    private var notAuthorizedBranch: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusChip(tone: .sage, text: "Signed in to Claude Code")
            Text("Last step — authorize the Google Calendar connector in your Claude.ai settings.")
                .font(.system(size: 12))
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(2)

            // Quiet URL display
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundColor(MagpieColors.slateText)
                Text("claude.ai/settings/connectors")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(MagpieColors.darkPlum)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(MagpieColors.paperWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(MagpieColors.slate.opacity(0.25), lineWidth: 0.5)
                    )
            )

            HStack(spacing: 8) {
                Button("Authorize Google Calendar") {
                    if let url = URL(string: "https://claude.ai/settings/connectors") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderedProminent)
                .tint(MagpieColors.sandstone)

                Button("Test connection") { runProbe() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.bordered)
            }

            Text("Or skip — you can do this later from the popover.")
                .font(.custom("Lora", size: 11.5))
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
        }
        .padding(.leading, 40)
    }

    @ViewBuilder
    private func probeErrorBranch(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusChip(tone: .amber, text: "Calendar probe failed")
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(2)
                .lineLimit(3)

            Button("Try again") { runProbe() }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.bordered)
        }
        .padding(.leading, 40)
    }

    @ViewBuilder
    private func statusChip(tone: ChipTone, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone == .amber ? MagpieColors.amberText : MagpieColors.sageTintFg)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tone == .amber ? MagpieColors.amberText : MagpieColors.sageTintFg)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tone == .amber ? MagpieColors.amberTintBg : MagpieColors.sageTintBg)
        )
    }

    private enum ChipTone { case amber, sage }

    // MARK: - Probe

    private func runProbe() {
        probeTask?.cancel()
        calendarBranch = .probing
        probeTask = Task { @MainActor in
            let result = await calendarService.probeForOnboarding()
            switch result {
            case .success:
                calendarBranch = .ready
                UserDefaults.standard.set(true, forKey: CalendarPrefs.alertsEnabled)
            case .signedOutOrMissing:
                calendarBranch = .signedOut
            case .notAuthorized(let hint):
                calendarBranch = .notAuthorized(hint: hint)
            case .otherFailure(let detail):
                calendarBranch = .probeError(detail: detail)
            }
        }
    }

    private func openTerminalWithLoginHint() {
        // Open Terminal.app — it'll come to the foreground and the user can paste
        // `claude /login`. We don't AppleScript-pipe a command because that
        // requires Automation TCC.
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    }

    // MARK: - Reusable bits

    private var doneTag: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("Done")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(MagpieColors.sageTintFg)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(MagpieColors.sageTintBg))
    }
}
