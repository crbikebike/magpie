// Sources/OnboardingView.swift
// Magpie — First-run permissions and vault setup.
//
// Visual implementation of the Magpie Calendar Surfaces design: 520pt-wide
// modal, eggshell page, italic-serif row details, sandstone Done button,
// branched calendar setup with status chips. Inter (sans) + Lora (serif)
// must be bundled in Resources/fonts/ — registered via ATSApplicationFontsPath
// in Info.plist. SwiftUI silently falls back to system serif if Lora isn't
// loaded, which is what made earlier builds look like Helvetica/Georgia.

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Calendar onboarding state

/// Outcome of probing the Claude Code Google Calendar connector.
enum CalendarOnboardingBranch: Equatable {
    case probing
    case signedOut
    case notAuthorized(hint: String)
    case ready
    case probeError(detail: String)
}

// MARK: - View

struct OnboardingView: View {
    @EnvironmentObject var model: RecorderModel
    let calendarService: CalendarService
    var onDone: (() -> Void)? = nil

    @State private var calendarBranch: CalendarOnboardingBranch
    @State private var probeTask: Task<Void, Never>? = nil

    init(calendarService: CalendarService = CalendarService(), onDone: (() -> Void)? = nil) {
        self.calendarService = calendarService
        self.onDone = onDone
        let alreadyEnabled = UserDefaults.standard.bool(forKey: CalendarPrefs.alertsEnabled)
        _calendarBranch = State(initialValue: alreadyEnabled ? .ready : .signedOut)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            vaultRow
            hairline
            micRow
            if #available(macOS 14.2, *) {
                hairline
                sysAudioRow
            }
            hairline
            calendarRow
            hairline
            footer
        }
        .frame(width: 520)
        .background(MagpieColors.eggshell)
        .onDisappear { probeTask?.cancel() }
    }

    // MARK: - Tokens

    private var hairline: some View {
        Rectangle()
            .fill(MagpieColors.paleSky)
            .frame(height: 0.5)
    }

    private static let sansTitle = Font.custom("Inter", size: 17).weight(.medium)
    private static let sansRowTitle = Font.custom("Inter", size: 13).weight(.medium)
    private static let sansBody = Font.custom("Inter", size: 12.5)
    private static let sansSmall = Font.custom("Inter", size: 11.5).weight(.medium)
    private static let sansButton = Font.custom("Inter", size: 12).weight(.medium)
    private static let sansDone = Font.custom("Inter", size: 13).weight(.medium)
    private static let serifSubtitle = Font.custom("Lora", size: 12.5)
    private static let serifDetail = Font.custom("Lora", size: 12)
    private static let serifHint = Font.custom("Lora", size: 11.5)
    private static let monoUrl = Font.system(size: 12, design: .monospaced)

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Magpie")
                .font(Self.sansTitle)
                .foregroundColor(MagpieColors.darkPlum)
            Text("Four small grants and Magpie will get out of your way. Everything stays on your Mac.")
                .font(Self.serifSubtitle)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Rows

    private var vaultRow: some View {
        let configured = model.vaultPath != nil
        let detail = configured
            ? (model.vaultPath?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            : "Where Magpie writes recordings and transcripts"
        return rowShell(
            icon: "folder",
            title: "Output folder",
            detail: detail,
            iconColor: configured ? MagpieColors.sageTintFg : MagpieColors.plumCharcoal,
            action: {
                if configured {
                    doneTag
                } else {
                    primaryButton("Choose") { model.pickVault() }
                }
            },
            body: { EmptyView() }
        )
    }

    private var micRow: some View {
        rowShell(
            icon: "mic",
            title: "Microphone",
            detail: model.micPermission == .authorized
                ? "Capturing your voice"
                : "Record your voice for transcription",
            iconColor: model.micPermission == .authorized
                ? MagpieColors.sageTintFg : MagpieColors.plumCharcoal,
            action: { micAction },
            body: { micBody }
        )
    }

    @ViewBuilder
    private var micAction: some View {
        switch model.micPermission {
        case .authorized:
            doneTag
        case .denied:
            secondaryButton("Open Settings") { openSettings(mic: true) }
        default:
            primaryButton("Enable") { model.requestMicPermission() }
        }
    }

    @ViewBuilder
    private var micBody: some View {
        if model.micPermission == .denied {
            Text("Magpie needs mic access to record your voice — grant it in System Settings, then come back.")
                .font(Self.serifHint)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @available(macOS 14.2, *)
    private var sysAudioRow: some View {
        let auth = model.sysAudioPermission == .authorized
        return rowShell(
            icon: "speaker.wave.2",
            title: "System audio",
            detail: auth
                ? "Capturing both sides of calls"
                : "Capture both sides of Zoom, Meet, and Teams calls",
            iconColor: auth ? MagpieColors.sageTintFg : MagpieColors.plumCharcoal,
            action: { sysAudioAction },
            body: { sysAudioBody }
        )
    }

    @ViewBuilder
    private var sysAudioAction: some View {
        switch model.sysAudioPermission {
        case .authorized:
            doneTag
        case .denied:
            secondaryButton("Open Settings") { openSettings(mic: false) }
        case .notDetermined:
            primaryButton("Enable") { model.requestSysAudioPermission() }
        }
    }

    @ViewBuilder
    private var sysAudioBody: some View {
        if model.sysAudioPermission != .authorized {
            Text("Optional. You can skip this and stay mic-only; you can also enable it later from Settings.")
                .font(Self.serifHint)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var calendarRow: some View {
        let isReady = calendarBranch == .ready
        return rowShell(
            icon: "calendar",
            title: "Calendar alerts",
            detail: calendarDetailText,
            iconColor: isReady ? MagpieColors.sageTintFg
                : (isProblemBranch ? MagpieColors.amberText : MagpieColors.plumCharcoal),
            action: {
                if isReady { doneTag }
            },
            body: { calendarBody }
        )
    }

    private var isProblemBranch: Bool {
        switch calendarBranch {
        case .signedOut, .notAuthorized, .probeError: return true
        default: return false
        }
    }

    private var calendarDetailText: String {
        switch calendarBranch {
        case .ready:           return "Prompting you 30 seconds before each meeting"
        case .signedOut:       return "Reads your calendar through Claude Code · optional"
        case .notAuthorized:   return "Sign-in detected · one more grant to finish"
        case .probing:         return "Checking your Claude Code setup…"
        case .probeError:      return "Reads your calendar through Claude Code · optional"
        }
    }

    @ViewBuilder
    private var calendarBody: some View {
        switch calendarBranch {
        case .ready:                    EmptyView()
        case .probing:                  ProgressView().scaleEffect(0.6)
        case .signedOut:                signinBranch
        case .notAuthorized:            authorizeBranch
        case .probeError(let detail):   probeErrorBranch(detail: detail)
        }
    }

    // MARK: - Calendar branches

    private var signinBranch: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusChip(amber: true, text: "Not signed in to Claude Code")
            Text("Magpie asks Claude Code to read your calendar — so events stay on your machine and Magpie never sees your Google credentials directly. Sign in to Claude Code to begin.")
                .font(Self.sansBody)
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                primaryButton("Open Claude Code") { openClaudeCodeTerminal() }
                secondaryButton("Re-check") { runProbe() }
            }
            Text("Run `claude /login` in your terminal, then click Re-check.")
                .font(Self.serifHint)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
        }
    }

    private var authorizeBranch: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusChip(amber: false, text: "Signed in to Claude Code")
            Text("Last step — authorize the Google Calendar connector in your Claude.ai settings. We'll open the page for you.")
                .font(Self.sansBody)
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            urlChip("claude.ai/settings/connectors")
            HStack(spacing: 10) {
                primaryButton("Authorize Google Calendar") {
                    if let url = URL(string: "https://claude.ai/settings/connectors") {
                        NSWorkspace.shared.open(url)
                    }
                }
                secondaryButton("Test connection") { runProbe() }
            }
            Text("Or skip — you can do this later from Settings.")
                .font(Self.serifHint)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
        }
    }

    @ViewBuilder
    private func probeErrorBranch(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            statusChip(amber: true, text: "Calendar probe failed")
            Text(detail)
                .font(Self.sansBody)
                .foregroundColor(MagpieColors.slateText)
                .lineSpacing(3)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            secondaryButton("Try again") { runProbe() }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(canFinish
                 ? "You're all set."
                 : "Mic + folder are required. Everything else is optional.")
                .font(Self.serifHint)
                .italic()
                .foregroundColor(MagpieColors.plumCharcoal)
                .frame(maxWidth: .infinity, alignment: .leading)

            doneButton
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var canFinish: Bool {
        model.vaultPath != nil && model.micPermission == .authorized
    }

    private var doneButton: some View {
        Button {
            model.showOnboarding = false
            model.refreshPermissions()
            onDone?()
        } label: {
            Text("Done")
                .font(Self.sansDone)
                .foregroundColor(canFinish ? MagpieColors.onSandstone
                                            : MagpieColors.onSandstone.opacity(0.55))
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(canFinish ? MagpieColors.sandstone
                                        : MagpieColors.sandstone.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canFinish)
    }

    // MARK: - Row shell

    private func rowShell<Action: View, Body: View>(
        icon: String,
        title: String,
        detail: String,
        iconColor: Color,
        @ViewBuilder action: () -> Action,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Self.sansRowTitle)
                        .foregroundColor(MagpieColors.darkPlum)
                    Text(detail)
                        .font(Self.serifDetail)
                        .italic()
                        .foregroundColor(MagpieColors.plumCharcoal)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                action()
            }

            body()
                .padding(.leading, 42)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Reusable bits

    private var doneTag: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("Done")
                .font(Self.sansSmall)
        }
        .foregroundColor(MagpieColors.sageTintFg)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(MagpieColors.sageTintBg))
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Self.sansButton)
                .foregroundColor(MagpieColors.onSandstone)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(MagpieColors.sandstone)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Self.sansButton)
                .foregroundColor(MagpieColors.plumCharcoal)
                .padding(.horizontal, 14)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(MagpieColors.slate.opacity(0.65), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func statusChip(amber: Bool, text: String) -> some View {
        let bg = amber ? MagpieColors.amberTintBg : MagpieColors.sageTintBg
        let fg = amber ? MagpieColors.amberText : MagpieColors.sageTintFg
        return HStack(spacing: 6) {
            Circle().fill(fg).frame(width: 6, height: 6)
            Text(text)
                .font(.custom("Inter", size: 11).weight(.medium))
                .foregroundColor(fg)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(bg))
    }

    private func urlChip(_ url: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundColor(MagpieColors.slateText)
            Text(url)
                .font(Self.monoUrl)
                .foregroundColor(MagpieColors.darkPlum)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(MagpieColors.paperWhite)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(MagpieColors.paleSky, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Actions

    private func openSettings(mic: Bool) {
        let key = mic
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: key) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openClaudeCodeTerminal() {
        if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminalURL)
        }
    }

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
}
