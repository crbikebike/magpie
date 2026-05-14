// Sources/FloatingPillWindow.swift
// Magpie — Floating pill window for always-visible recording controls.
//
// An NSPanel subclass that provides an independent, always-on-top recording
// indicator excluded from screen shares. Position persisted via UserDefaults.
//
// Variable height — see `applyHeight(for:)`. The window grows downward when
// a calendar prompt drawer expands beneath the recording pill, and shrinks
// back to the bare 36pt pill after the drawer dismisses.

import AppKit

final class FloatingPillWindow: NSPanel {

    // UserDefaults key for persisted position
    static let positionKey = "floatingPillOrigin"

    // Heights per pill mode — must stay in sync with FloatingPillView.
    private static let heightHidden: CGFloat = 36
    private static let heightRecording: CGFloat = 36
    private static let heightIdlePrompt: CGFloat = 44
    private static let heightRecordingWithDrawer: CGFloat = 148

    /// Default width — the design pegs the prompt pill and drawer pill at
    /// 320pt. The recording pill is narrower (hug-content) but the window
    /// hosts a hosting controller that lays out at this width.
    private static let pillWidth: CGFloat = 320

    // Default position: top-right, 80pt from right edge, 60pt from top.
    func defaultOrigin(for screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let x = visible.maxX - 80 - frame.width
        let y = visible.maxY - 60
        return NSPoint(x: x, y: y)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.heightRecording),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .none
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        // System window shadow draws around the full content rect (320pt
        // wide), not the SwiftUI alpha mask — so it leaks a faint outline
        // to the right of the pill, which is hug-content and only ~175pt
        // wide. PillBackground already draws its own SwiftUI shadow that
        // tracks the actual pill shape, so the window shadow is redundant.
        hasShadow = false
    }

    /// Show the pill at persisted position (or default).
    func showPill() {
        let origin = loadPosition()
        setFrameOrigin(origin)
        orderFront(nil)
    }

    /// Hide the pill.
    func hidePill() {
        orderOut(nil)
    }

    /// Resize the window for the given pill mode, keeping the top-left
    /// corner anchored so the pill grows downward (drawer reveal) rather
    /// than upward off-screen.
    func applyHeight(for mode: PillMode) {
        let newHeight = height(for: mode)
        let current = frame
        // Bail when the height already matches (the common .hidden →
        // .recording transition: window stays at 36pt). Even setting the
        // hosting view's frame to its current value triggers a layout
        // pass; wrapping a same-size setFrame in NSAnimationContext fires
        // the animation start/end cycle for nothing. Both paths stack with
        // SwiftUI's first-paint work and contribute to the recursion seen
        // in issue #14.
        guard abs(current.height - newHeight) > 0.5 else { return }

        // Anchor by top-left: in AppKit, the frame origin is bottom-left in
        // screen coordinates, so to keep the top edge fixed we shift origin.y
        // by (current.height - new.height).
        let dy = current.height - newHeight
        let newFrame = NSRect(
            x: current.origin.x,
            y: current.origin.y + dy,
            width: current.width,
            height: newHeight
        )
        // Push the hosting view's frame size first so SwiftUI re-lays out at
        // the new height in the same tick — and we don't depend on
        // autoresizingMask (which feeds the layout recursion on Tahoe — see
        // issue #11). Then animate the panel to match.
        contentViewController?.view.frame = NSRect(
            x: 0, y: 0, width: current.width, height: newHeight
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    private func height(for mode: PillMode) -> CGFloat {
        switch mode {
        case .hidden:               return Self.heightHidden
        case .recording:            return Self.heightRecording
        case .idlePrompt:           return Self.heightIdlePrompt
        case .recordingWithDrawer:  return Self.heightRecordingWithDrawer
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        savePosition()
    }

    /// Load persisted origin, falling back to defaultOrigin.
    func loadPosition() -> NSPoint {
        guard let stored = UserDefaults.standard.string(forKey: Self.positionKey) else {
            return defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
        }

        let parts = stored.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
        }

        let point = NSPoint(x: x, y: y)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(point) }
        return onScreen ? point : defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
    }

    /// Save current origin to UserDefaults.
    func savePosition() {
        let origin = frame.origin
        let value = "\(origin.x),\(origin.y)"
        UserDefaults.standard.set(value, forKey: Self.positionKey)
    }
}
