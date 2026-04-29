// Sources/RecorderModel.swift
// Magpie — Recording state machine.
//
// Routes recording to MicSession (mic only), SystemAudioSession (system only),
// or MixedSession (mic + system) based on audioMode. CAF-format sessions are
// converted to M4A after stop, before passing to Yap transcription.

import AppKit
import AVFoundation
import Combine
import Foundation

// MARK: - Audio Mode

enum AudioMode: String, CaseIterable, Identifiable {
    case micOnly      = "Mic Only"
    case systemOnly   = "System Only"
    case micAndSystem = "Mic + System"
    var id: String { rawValue }
}

// MARK: - System Audio Status

enum SystemAudioFailureReason: Equatable {
    case generic(String)
    case permissionDenied
    case coreaudiodStall
}

enum SystemAudioStatus: Equatable {
    case active
    case unavailable(reason: SystemAudioFailureReason)
    case interrupted
    case reconnected
    case notApplicable
    case micUnavailable   // another app has exclusive mic access (e.g. Zoom)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.active, .active):               return true
        case (.unavailable(let a), .unavailable(let b)): return a == b
        case (.interrupted, .interrupted):     return true
        case (.reconnected, .reconnected):     return true
        case (.notApplicable, .notApplicable): return true
        case (.micUnavailable, .micUnavailable): return true
        default:                               return false
        }
    }
}

// MARK: - RecorderModel

class RecorderModel: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isRecording = false
    @Published var activeTranscriptions = 0
    var isTranscribing: Bool { activeTranscriptions > 0 }
    @Published var audioMode: AudioMode = .micOnly
    @Published var vaultPath: URL?
    @Published var recentTranscripts: [URL] = []
    @Published var statusMessage = ""
    @Published var elapsedSeconds = 0
    @Published var audioLevel: Float = 0
    @Published var micPermission: AVAuthorizationStatus = .notDetermined
    @Published var showOnboarding: Bool = false

    // System audio state
    @Published var sysAudioPermission: SystemAudioSession.Permission = .notDetermined
    @Published var showFirstRecordingConfirmation = false
    @Published var headphoneNudgeDismissed = false
    @Published var systemAudioStatus: SystemAudioStatus = .notApplicable {
        didSet {
            if systemAudioStatus == .reconnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.systemAudioStatus == .reconnected {
                        self?.systemAudioStatus = .active
                    }
                }
            }
        }
    }

    var needsPermissionsOnboarding: Bool {
        vaultPath == nil || micPermission != .authorized
    }

    /// True when the one-time headphone nudge should be displayed.
    /// Checks the dismissed flag, the UserDefaults sentinel, the current mode,
    /// and the live headphone state so callers don't need to replicate the logic.
    var needsHeadphoneNudge: Bool {
        !headphoneNudgeDismissed
            && !UserDefaults.standard.bool(forKey: "headphone_nudge_shown")
            && audioMode == .micOnly
            && HeadphoneDetector.headphonesConnected()
    }

    private var activeSession: RecordingSession?
    private var levelMonitor: AudioLevelMonitor?
    private var recordingURL: URL?
    private var elapsedTimer: Timer?
    var lastStopTime: Date?
    let recordingCooldownSeconds: TimeInterval = 2

    override init() {
        super.init()
        loadVaultPath()
        refreshPermissions()
    }

    // MARK: - Vault

    private func loadVaultPath() {
        if let path = UserDefaults.standard.string(forKey: "apertureVaultPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                vaultPath = url
                loadRecentTranscripts()
            }
        }
    }

    func pickVault() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.message = "Where Magpie saves transcripts and summaries"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "apertureVaultPath")
        DispatchQueue.main.async {
            self.vaultPath = url
            self.loadRecentTranscripts()
            self.installWatcherAgent()
        }
    }

    func loadRecentTranscripts() {
        guard let vault = vaultPath else { return }
        let dir = vault   // flat — transcripts are in the root
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let sorted = files
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".summary.md") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        DispatchQueue.main.async {
            self.recentTranscripts = Array(sorted.prefix(3))
        }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        let probe = SystemAudioSession.currentPermission()
        if probe == .denied {
            sysAudioPermission = .denied
        } else {
            sysAudioPermission = .authorized
        }
    }

    func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPermissions() }
        }
    }

    func requestSysAudioPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let result = SystemAudioSession.requestPermission()
        DispatchQueue.main.async { self.sysAudioPermission = result }
    }

    // MARK: - Watcher Management

    var isWatcherRunning: Bool {
        guard let vault = vaultPath else { return false }
        let pidPath = vault.appendingPathComponent(".watcher.pid")
        guard let pidStr = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    func installWatcherAgent() {
        guard let vault = vaultPath else { return }
        guard let watcherURL = Bundle.main.url(forResource: "watcher", withExtension: "py") else {
            log("watcher.py not found in app bundle — skipping agent install", vaultPath: vault)
            return
        }
        let python3Candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python3 = python3Candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            log("python3 not found — cannot install watcher agent", vaultPath: vault)
            return
        }
        let basePath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let claudeCandidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claudeDir = claudeCandidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let resolvedPath = claudeDir.map { "\($0):\(basePath)" } ?? basePath

        let plistLabel = "com.crbikebike.magpie.watcher"
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(plistLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(python3)</string>
                <string>\(watcherURL.path)</string>
                <string>--output</string>
                <string>\(vault.path)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(resolvedPath)</string>
            </dict>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(vault.path)/.watcher-stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(vault.path)/.watcher-stderr.log</string>
            <key>WorkingDirectory</key>
            <string>\(vault.path)</string>
        </dict>
        </plist>
        """
        let agentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = agentsDir.appendingPathComponent("\(plistLabel).plist")
        do {
            try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
        } catch {
            log("Failed to write watcher plist: \(error.localizedDescription)", vaultPath: vault)
            return
        }
        // Unload any existing agent (ignore error — may not be loaded)
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["bootout", "gui/\(getuid())", plistPath.path]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run(); unload.waitUntilExit()
        // Load new agent
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["bootstrap", "gui/\(getuid())", plistPath.path]
        load.standardOutput = FileHandle.nullDevice
        load.standardError = FileHandle.nullDevice
        try? load.run(); load.waitUntilExit()
        log("Watcher agent installed — output=\(vault.path)", vaultPath: vault)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func uninstallWatcherAgent() {
        let plistLabel = "com.crbikebike.magpie.watcher"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())", plistPath.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run(); proc.waitUntilExit()
        try? FileManager.default.removeItem(at: plistPath)
        log("Watcher agent uninstalled", vaultPath: vaultPath)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func toggleWatcher() {
        if isWatcherRunning {
            uninstallWatcherAgent()
        } else {
            installWatcherAgent()
        }
    }

    // MARK: - Recording

    func startRecording() {
        if let last = lastStopTime, Date().timeIntervalSince(last) < recordingCooldownSeconds {
            statusMessage = "Finishing up — try again in a sec"
            return
        }
        guard !isRecording else { return }
        guard vaultPath != nil else {
            statusMessage = "Select an output folder first."
            return
        }

        // Mic permission required for mic-involving modes
        if audioMode == .micOnly || audioMode == .micAndSystem {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                statusMessage = "Microphone access required — use the permissions screen."
                return
            }
        }

        // System audio permission required for system-involving modes
        if audioMode == .systemOnly || audioMode == .micAndSystem {
            guard sysAudioPermission == .authorized else {
                statusMessage = "System audio permission required — use the permissions screen."
                return
            }
        }

        // Set initial system audio status before creating the session
        switch audioMode {
        case .micOnly:
            systemAudioStatus = .notApplicable
        case .systemOnly, .micAndSystem:
            systemAudioStatus = .active  // optimistic; overridden on failure
        }

        let session: RecordingSession
        let tempURL: URL

        do {
            switch audioMode {
            case .micOnly:
                let m4a = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aperture-\(Int(Date().timeIntervalSince1970)).m4a")
                let mic = MicSession()
                try mic.start(to: m4a)
                session = mic
                tempURL = m4a
            case .systemOnly:
                let caf = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aperture-\(Int(Date().timeIntervalSince1970)).caf")
                let sys = SystemAudioSession()
                sys.onSystemAudioStatusChange = { [weak self] status in
                    DispatchQueue.main.async { self?.systemAudioStatus = status }
                }
                do {
                    try sys.start(to: caf)
                } catch {
                    let reason: SystemAudioFailureReason = .generic(error.localizedDescription)
                    systemAudioStatus = .unavailable(reason: reason)
                    statusMessage = "System audio unavailable. Switch to Mic + System or check System Settings."
                    log("System audio start failed: \(error.localizedDescription)", vaultPath: vaultPath)
                    return
                }
                session = sys
                tempURL = caf
            case .micAndSystem:
                let caf = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aperture-\(Int(Date().timeIntervalSince1970)).caf")
                let mixed = MixedSession()
                mixed.onSystemAudioStatusChange = { [weak self] status in
                    DispatchQueue.main.async { self?.systemAudioStatus = status }
                }
                mixed.vaultPath = vaultPath  // enable vault logging for diagnostics
                try mixed.start(to: caf)
                session = mixed
                tempURL = caf
            }
        } catch let err as MicUnavailableError {
            statusMessage = err.localizedDescription
            systemAudioStatus = .micUnavailable
            log("Mic unavailable: \(err.localizedDescription)", vaultPath: vaultPath)
            return
        } catch {
            statusMessage = "Could not start recording: \(error.localizedDescription)"
            log("Recording start failed: \(error.localizedDescription)", vaultPath: vaultPath)
            return
        }

        activeSession = session
        recordingURL = tempURL

        let monitor = AudioLevelMonitor(session: session) { [weak self] level in
            self?.audioLevel = level
        }
        levelMonitor = monitor
        monitor.start()

        log("Recording started — \(audioMode.rawValue), temp: \(tempURL.lastPathComponent)", vaultPath: vaultPath)

        isRecording = true
        elapsedSeconds = 0
        statusMessage = ""
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedSeconds += 1
            if self.elapsedSeconds == 5 && self.audioLevel < 0.01 {
                self.statusMessage = "⚠ No audio detected — check mic permission and try again"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        lastStopTime = Date()
        systemAudioStatus = .notApplicable
        log("Recording stopped — duration: \(elapsedSeconds)s", vaultPath: vaultPath)

        elapsedTimer?.invalidate()
        elapsedTimer = nil

        levelMonitor?.stop()
        levelMonitor = nil

        activeSession?.stop()
        activeSession = nil

        audioLevel = 0

        let capturedURL = recordingURL
        let duration = elapsedSeconds
        let capturedMode = audioMode

        recordingURL = nil
        isRecording = false
        activeTranscriptions += 1
        statusMessage = ""

        guard let audioURL = capturedURL else {
            activeTranscriptions = max(activeTranscriptions - 1, 0)
            return
        }

        Task { await self.transcribe(audioURL: audioURL, durationSeconds: duration, mode: capturedMode) }
    }

    // MARK: - Transcription

    private func transcribe(audioURL: URL, durationSeconds: Int, mode: AudioMode) async {
        let isCAF = audioURL.pathExtension.lowercased() == "caf"
        var convertedM4A: URL? = nil
        var retainedAudio = false

        defer {
            // Clean up original CAF temp file (always — the M4A is the keeper)
            if isCAF {
                try? FileManager.default.removeItem(at: audioURL)
            }
            // Only delete M4A if we didn't retain it in the vault
            if !retainedAudio {
                if let m4a = convertedM4A {
                    try? FileManager.default.removeItem(at: m4a)
                } else {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
        }

        let yapInputURL: URL
        if isCAF {
            let m4a = audioURL.deletingPathExtension().appendingPathExtension("m4a")
            convertedM4A = m4a
            do {
                log("Converting CAF→M4A: \(audioURL.lastPathComponent)", vaultPath: vaultPath)
                try await convertCAFtoM4A(src: audioURL, dst: m4a)
                yapInputURL = m4a
            } catch {
                log("CAF→M4A conversion failed: \(error.localizedDescription)", vaultPath: vaultPath)
                try? FileManager.default.removeItem(at: audioURL)
                if let m4a = convertedM4A { try? FileManager.default.removeItem(at: m4a) }
                DispatchQueue.main.async {
                    self.activeTranscriptions = max(self.activeTranscriptions - 1, 0)
                    self.statusMessage = "Conversion failed: \(error.localizedDescription)"
                }
                return
            }
        } else {
            yapInputURL = audioURL
        }

        let vault = vaultPath
        log("Transcription started — \(yapInputURL.lastPathComponent), \(durationSeconds)s", vaultPath: vault)

        guard let vault else {
            log("ERROR: No vault configured", vaultPath: nil)
            try? FileManager.default.removeItem(at: audioURL)
            if let m4a = convertedM4A { try? FileManager.default.removeItem(at: m4a) }
            DispatchQueue.main.async {
                self.activeTranscriptions = max(self.activeTranscriptions - 1, 0)
                self.statusMessage = "No vault configured."
            }
            return
        }

        guard let yapPath = findExecutable("yap") else {
            log("ERROR: yap not found — checked /opt/homebrew/bin, /usr/local/bin, /usr/bin", vaultPath: vault)
            try? FileManager.default.removeItem(at: audioURL)
            if let m4a = convertedM4A { try? FileManager.default.removeItem(at: m4a) }
            DispatchQueue.main.async {
                self.activeTranscriptions = max(self.activeTranscriptions - 1, 0)
                self.showYapMissingAlert()
            }
            return
        }

        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: yapPath)
            proc.arguments = ["transcribe", yapInputURL.path, "--txt"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            log("Running: \(yapPath) transcribe \(yapInputURL.lastPathComponent) --txt", vaultPath: vault)
            try proc.run()

            // Read pipes BEFORE waitUntilExit — avoids pipe-buffer deadlock when yap
            // produces more output than the buffer can hold.
            let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData  = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            log("yap exit: \(proc.terminationStatus), output: \(output.count) chars", vaultPath: vault)
            if !errOutput.isEmpty {
                log("yap stderr: \(errOutput)", vaultPath: vault)
            }

            if proc.terminationStatus != 0 {
                let detail = errOutput.isEmpty ? "" : ": \(errOutput)"
                throw NSError(
                    domain: "Yap",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey:
                        "Transcription failed (yap exit \(proc.terminationStatus))\(detail)"]
                )
            }

            if output.isEmpty {
                throw NSError(
                    domain: "Yap",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No speech detected — try a longer recording or speak closer to the mic"]
                )
            }

            let mdURL = try writeMarkdown(transcript: output, vault: vault, durationSeconds: durationSeconds)
            log("Saved: \(mdURL.lastPathComponent)", vaultPath: vault)

            // Retain audio in vault — watcher links it to the transcript, /evening cleans up after triage
            let audioDir = vault.appendingPathComponent("inbox/audio")
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            let audioName = mdURL.deletingPathExtension().lastPathComponent + ".m4a"
            let audioDestURL = audioDir.appendingPathComponent(audioName)
            let sourceM4A = convertedM4A ?? audioURL
            do {
                try FileManager.default.moveItem(at: sourceM4A, to: audioDestURL)
                retainedAudio = true
                log("Audio retained: inbox/audio/\(audioName)", vaultPath: vault)
            } catch {
                log("Audio retention failed: \(error.localizedDescription)", vaultPath: vault)
            }

            DispatchQueue.main.async {
                self.activeTranscriptions = max(self.activeTranscriptions - 1, 0)
                self.loadRecentTranscripts()
                self.statusMessage = "Saved: \(mdURL.lastPathComponent)"

                // Post-first-recording confirmation for system audio modes (shown once only)
                if mode != .micOnly
                    && !UserDefaults.standard.bool(forKey: "sysaudio_first_recording_confirmed")
                {
                    UserDefaults.standard.set(true, forKey: "sysaudio_first_recording_confirmed")
                    self.showFirstRecordingConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.showFirstRecordingConfirmation = false
                    }
                }
            }

        } catch {
            log("ERROR: \(error.localizedDescription)", vaultPath: vault)
            // Delete both temp files on failure — same as original defer behavior
            try? FileManager.default.removeItem(at: audioURL)
            if let m4a = convertedM4A {
                try? FileManager.default.removeItem(at: m4a)
            }
            DispatchQueue.main.async {
                self.activeTranscriptions = max(self.activeTranscriptions - 1, 0)
                self.statusMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    private func showYapMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Yap Not Installed"
        alert.informativeText = "Yap is required for transcription.\n\nInstall it with:\n\n  brew install yap\n\nThen try recording again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
