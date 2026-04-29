// Sources/App.swift
// Magpie — App entry point and AppDelegate.

import AppKit
import Combine
import SwiftUI

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
    private var hotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let iconURL = Bundle.main.url(forResource: "raven", withExtension: "svg"),
               let img = NSImage(contentsOf: iconURL) {
                img.isTemplate = true
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Magpie")
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(
            rootView: RecorderView().environmentObject(recorder)
        )
        showOnboardingPanelIfNeeded()
        // Install watcher if vault already configured (returning user)
        if !recorder.needsPermissionsOnboarding {
            recorder.installWatcherAgent()
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
                    if let iconURL = Bundle.main.url(forResource: "raven", withExtension: "svg"),
                       let img = NSImage(contentsOf: iconURL) {
                        img.isTemplate = true
                        button.image = img
                    } else {
                        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Magpie")
                    }
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
    }

    /// Create the FloatingPillWindow, wire it to RecorderModel state.
    private func setupPillWindow() {
        let pill = FloatingPillWindow()
        pill.contentViewController = NSHostingController(
            rootView: FloatingPillView().environmentObject(recorder)
        )
        pill.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        pillWindow = pill

        // Show pill when recording starts; hide when recording AND transcribing both finish.
        // isTranscribing is a computed property, so use objectWillChange instead of $isTranscribing.
        pillVisibilityCancellable = recorder.$isRecording
            .combineLatest(recorder.objectWillChange.map { [weak self] _ in self?.recorder.isTranscribing ?? false })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (isRecording, isTranscribing) in
                guard let self, let pill = self.pillWindow else { return }
                if isRecording || isTranscribing {
                    pill.showPill()
                } else {
                    pill.hidePill()
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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Magpie"
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = OnboardingView(onDone: { [weak self] in self?.closeOnboardingPanel() })
            .environmentObject(recorder)
        panel.contentViewController = NSHostingController(rootView: content)
        panel.setContentSize(NSSize(width: 320, height: 380))
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

    @objc func openPermissions() {
        showOnboardingPanel()
    }
}
