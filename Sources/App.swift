// Sources/App.swift
// Magpie — App entry point and AppDelegate.

import AppKit
import Combine
import SwiftUI

// MARK: - UserDefaults KVO

/// KVO-observable property whose Objective-C name matches the
/// `calendarAlertsEnabled` UserDefaults key. Lets Combine's
/// `.publisher(for:)` surface preference changes immediately.
extension UserDefaults {
    @objc dynamic var calendarAlertsEnabled: Bool {
        bool(forKey: "calendarAlertsEnabled")
    }
}

// MARK: - Entry Point

@main
struct MagpieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var onboardingPanel: NSPanel?
    var eventMonitor: Any?
    let recorder = RecorderModel()
    private var recordingTintCancellable: AnyCancellable?

    // Floating pill
    var pillWindow: FloatingPillWindow?
    private var pillVisibilityCancellable: AnyCancellable?
    private var pillModeCancellable: AnyCancellable?
    private var hotkeyMonitor: Any?

    // Calendar — fetcher + scheduler. Scheduler is started/stopped based on
    // the user's `calendarAlertsEnabled` preference.
    let calendarService = CalendarService()
    var meetingScheduler: MeetingScheduler?
    private var failureDotCancellable: AnyCancellable?
    private var calendarPrefCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with NSSupportsAutomaticTermination=false in
        // Info.plist (issue #7). The popover-driven menubar app has no
        // standard windows when the popover is closed, so AppKit's TAL
        // would otherwise reap the GUI ~60s after dismissal — leaving the
        // watcher running and the user wondering why the pill never appears
        // on the next recording.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Magpie hosts a menubar UI and the floating recording pill; the GUI must outlive popover dismissal."
        )

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = ravenImage() ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Magpie")
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .applicationDefined
        popover.animates = true
        // Content-driven sizing. RecorderView measures its natural height via a
        // GeometryReader-in-background (read-only pass — does NOT use
        // sizingOptions or autoresizingMask, both of which feed Tahoe's
        // _NSDetectedLayoutRecursion path per issues #4, #6, #11) and
        // forwards it here. We clamp + dedupe before assigning so a flurry of
        // identical reports during one layout pass doesn't churn the panel.
        let rootView = RecorderView(onHeightChange: { [weak self] reported in
            guard let self else { return }
            let clamped = max(220, min(900, ceil(reported)))
            let newSize = NSSize(width: 320, height: clamped)
            guard self.popover.contentSize != newSize else { return }
            self.popover.contentSize = newSize
        })
        popover.contentViewController = NSHostingController(
            rootView: rootView
                .environmentObject(recorder)
                .environmentObject(calendarService)
        )
        showOnboardingPanelIfNeeded()
        // Install watcher if vault already configured (returning user)
        if !recorder.needsPermissionsOnboarding {
            recorder.installWatcherAgent()
        }

        // When the user explicitly requests system audio permission, lower the
        // Lower the onboarding panel before any TCC dialog so it appears in front.
        NotificationCenter.default.addObserver(forName: .willRequestMicPermission, object: nil, queue: .main) { [weak self] _ in
            self?.onboardingPanel?.level = .normal
        }
        NotificationCenter.default.addObserver(forName: .didRequestMicPermission, object: nil, queue: .main) { [weak self] _ in
            self?.onboardingPanel?.level = .floating
        }
        NotificationCenter.default.addObserver(forName: .willRequestSysAudioPermission, object: nil, queue: .main) { [weak self] _ in
            self?.onboardingPanel?.level = .normal
        }
        NotificationCenter.default.addObserver(forName: .didRequestSysAudioPermission, object: nil, queue: .main) { [weak self] _ in
            self?.onboardingPanel?.level = .floating
        }

        // Recording indicator: swap icon while recording.
        // contentTintColor on template images causes full transparency on macOS 14+.
        // Instead, swap to a non-template filled symbol with explicit palette color.
        recordingTintCancellable = recorder.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self else {
                    log("recording-tint: self is nil — AppDelegate may have been deallocated", vaultPath: nil)
                    return
                }
                guard let button = self.statusItem.button else {
                    log("recording-tint: statusItem.button is nil", vaultPath: self.recorder.vaultPath)
                    return
                }

                log("recording-tint: isRecording=\(isRecording), statusItem.isVisible=\(self.statusItem.isVisible), button.image=\(String(describing: button.image)), button.bounds=\(button.bounds), statusItem.length=\(self.statusItem.length)", vaultPath: self.recorder.vaultPath)

                if isRecording {
                    let config = NSImage.SymbolConfiguration(
                        paletteColors: [.red]
                    )
                    let baseImg = NSImage(
                        systemSymbolName: "record.circle.fill",
                        accessibilityDescription: "Magpie — Recording"
                    )
                    let img = baseImg?.withSymbolConfiguration(config)
                    log("recording-tint: baseImg=\(String(describing: baseImg)), configuredImg=\(String(describing: img))", vaultPath: self.recorder.vaultPath)
                    img?.isTemplate = false
                    button.image = img
                } else {
                    button.image = self.ravenImage() ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Magpie")
                    log("recording-tint: restore img=\(String(describing: button.image))", vaultPath: self.recorder.vaultPath)
                }
                button.contentTintColor = nil
                button.setAccessibilityLabel(isRecording
                    ? "Magpie — Recording"
                    : "Magpie")

                // Post-assignment check
                log("recording-tint: AFTER — button.image=\(String(describing: button.image)), button.bounds=\(button.bounds), isHidden=\(button.isHidden), alphaValue=\(button.alphaValue)", vaultPath: self.recorder.vaultPath)
            }

        // Floating pill window
        setupPillWindow()

        // Global hotkey Cmd+Shift+R
        registerGlobalHotkey()

        // Calendar — start scheduler if the user has alerts enabled, watch
        // for failure threshold + preference changes.
        setupCalendar()
    }

    /// Wire calendar scheduling + the menubar failure dot.
    private func setupCalendar() {
        // Amber dot overlay when fetch fails 3× in a row (and we're not currently recording).
        failureDotCancellable = Publishers.CombineLatest(
            calendarService.$consecutiveFailures,
            recorder.$isRecording
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] failures, isRecording in
            guard let self else { return }
            // Recording state owns the status icon while active.
            guard !isRecording, let button = self.statusItem.button else { return }
            let base = self.ravenImage() ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Magpie")
            if failures >= 3, let img = base.map({ self.imageWithAmberDot($0) }) {
                button.image = img
                button.toolTip = "Calendar sync failing — last 3 fetches couldn't reach Claude Code"
            } else {
                button.image = base
                button.toolTip = nil
            }
        }

        // Start the scheduler on the calendarAlertsEnabled flag — UserDefaults
        // KVO surfaces the change so toggling in prefs takes effect immediately.
        calendarPrefCancellable = UserDefaults.standard
            .publisher(for: \.calendarAlertsEnabled, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    if self.meetingScheduler == nil {
                        let sched = MeetingScheduler(
                            service: self.calendarService,
                            model: self.recorder
                        )
                        sched.start()
                        self.meetingScheduler = sched
                    }
                } else {
                    self.meetingScheduler?.stop()
                    self.meetingScheduler = nil
                }
            }
    }

    /// Overlay an 8pt amber circle on the top-right of the status item image.
    private func imageWithAmberDot(_ base: NSImage) -> NSImage {
        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        defer { composed.unlockFocus() }
        // Draw the raven image as a template (uses the status item's natural tint).
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        let dotDiameter: CGFloat = max(5, size.width * 0.35)
        let dotRect = NSRect(
            x: size.width - dotDiameter - 0.5,
            y: size.height - dotDiameter - 0.5,
            width: dotDiameter, height: dotDiameter
        )
        NSColor(red: 255 / 255, green: 166 / 255, blue: 43 / 255, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        composed.isTemplate = false  // amber must render in color
        return composed
    }

    /// Create the FloatingPillWindow, wire it to RecorderModel state.
    private func setupPillWindow() {
        let pill = FloatingPillWindow()
        let pillVC = NSHostingController(rootView: FloatingPillView().environmentObject(recorder))
        // Do NOT set sizingOptions = [.preferredContentSize] (issue #4/#6).
        // Do NOT set autoresizingMask either — on a borderless+nonactivating
        // panel + animated setFrame, autoresizing on the hosting view feeds
        // _NSDetectedLayoutRecursion at first paint and SwiftUI silently
        // drops the render pass (issue #11). Drive the hosting view's frame
        // explicitly from FloatingPillWindow.applyHeight(for:) instead.
        pillVC.view.translatesAutoresizingMaskIntoConstraints = true
        pillVC.view.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        pill.contentViewController = pillVC
        pillWindow = pill

        // Visibility + height both come from pillMode. Combine the three
        // inputs into one stream so we only react when the mode actually
        // changes — avoids flicker from per-tick audioLevel updates.
        let recordingSignal = Publishers.CombineLatest3(
            recorder.$isRecording,
            recorder.$activeTranscriptions,
            recorder.$pendingPrompt
        )
        .map { isRecording, transcriptions, prompt -> PillMode in
            let active = isRecording || (transcriptions > 0)
            switch (active, prompt != nil) {
            case (false, false): return .hidden
            case (false, true):  return .idlePrompt
            case (true,  false): return .recording
            case (true,  true):  return .recordingWithDrawer
            }
        }
        .removeDuplicates()

        pillModeCancellable = recordingSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self, let pill = self.pillWindow else { return }
                if mode == .hidden {
                    pill.hidePill()
                } else {
                    pill.applyHeight(for: mode)
                    if !pill.isVisible { pill.showPill() }
                }
            }
    }

    /// Register Cmd+Shift+R as global hotkey to toggle recording.
    private func registerGlobalHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // Cmd+Shift+R: modifiers = [.command, .shift], keyCode 15 = 'r'
            let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
            let pressedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if pressedFlags == requiredFlags && event.keyCode == 15 {
                DispatchQueue.main.async {
                    if self.recorder.isRecording {
                        self.recorder.stopRecording()
                    } else if !self.recorder.isTranscribing {
                        self.recorder.startRecording()
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
    }

    /// Refuse termination while a recording or transcription is in flight —
    /// losing the GUI mid-recording would orphan the audio file and leave
    /// the user with nothing to show for it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording || recorder.activeTranscriptions > 0 {
            return .terminateCancel
        }
        return .terminateNow
    }

    func showOnboardingPanelIfNeeded() {
        if recorder.needsPermissionsOnboarding {
            showOnboardingPanel()
        }
    }

    func showOnboardingPanel() {
        if let existing = onboardingPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        recorder.showOnboarding = true
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Magpie · First-run setup"
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = OnboardingView(
            calendarService: calendarService,
            onDone: { [weak self] in self?.closeOnboardingPanel() }
        )
        .environmentObject(recorder)
        let hosting = NSHostingController(rootView: content)
        // NB: do NOT set hosting.sizingOptions = [.preferredContentSize].
        // On macOS 26 (Tahoe) it loops in the constraint-update path and
        // AppKit kills the process before the window appears. See issue #6
        // (and #4 for the floating-pill instance of the same bug).
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: 520, height: 720))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingPanel = panel
    }

    func closeOnboardingPanel() {
        onboardingPanel?.orderOut(nil)
        onboardingPanel = nil
        recorder.showOnboarding = false
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            closePopover()
            let menu = NSMenu()
            menu.addItem(withTitle: "Check Permissions", action: #selector(openPermissions), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Magpie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { self.statusItem.menu = nil }
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startEventMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func ravenImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "raven", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    @objc func openPermissions() {
        showOnboardingPanel()
    }
}
