// Sources/OnboardingView.swift
// Magpie — First-run permissions and vault setup.

import AppKit
import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: RecorderModel
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("Magpie")
                    .font(.headline)
                Text("Set up permissions so your recordings capture what you need")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

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

            // Output folder row
            vaultRow

            Divider()

            // Done button — requires vault + mic; system audio is optional
            Button {
                model.showOnboarding = false
                model.refreshPermissions()
                onDone?()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.vaultPath == nil || model.micPermission != .authorized)
            .padding(16)
        }
        .frame(width: 300)
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
                .foregroundColor(model.vaultPath != nil ? MagpieColors.successGreen : MagpieColors.pencil)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Output Folder").font(.callout).fontWeight(.medium)
                if let vault = model.vaultPath {
                    Text(vault.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("Choose") { model.pickVault() }
                .font(.caption)
                .buttonStyle(.borderedProminent)
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
                .foregroundColor(status == .authorized ? MagpieColors.successGreen : MagpieColors.pencil)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            switch status {
            case .authorized:
                Text("✓ Done")
                    .font(.caption)
                    .foregroundColor(MagpieColors.successGreen)
            case .denied:
                VStack(alignment: .trailing, spacing: 2) {
                    if let detailText = deniedDetailText {
                        Text(detailText)
                            .font(.caption2)
                            .foregroundColor(MagpieColors.warningAmber)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: settingsURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            case .notDetermined:
                Button("Enable") { action() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
