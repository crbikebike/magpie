// Sources/FloatingPillWindow.swift
// Magpie — Floating pill window for always-visible recording controls.
//
// An NSPanel subclass that provides an independent, always-on-top recording
// indicator excluded from screen shares. Position persisted via UserDefaults.

import AppKit

final class FloatingPillWindow: NSPanel {

    // UserDefaults key for persisted position
    static let positionKey = "floatingPillOrigin"

    // Default position: top-right, 80pt from right edge, 60pt from top.
    // Uses actual frame width when available (post-layout); falls back to 160pt estimate.
    func defaultOrigin(for screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let pillWidth = frame.width > 0 ? frame.width : 160
        let x = visible.maxX - 80 - pillWidth
        let y = visible.maxY - 60
        return NSPoint(x: x, y: y)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
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
        hasShadow = true
    }

    /// Show the pill at persisted position (or default).
    func showPill() {
        let origin = loadPosition()
        setFrameOrigin(origin)
        orderFront(nil)
    }

    /// Hide the pill. Only callable when recording has stopped.
    func hidePill() {
        orderOut(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        savePosition()
    }

    /// Load persisted origin, falling back to defaultOrigin.
    /// Note: internal (not private) to allow direct test access from
    /// TestFloatingPill.swift, which compiles in the same module.
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

        // Check if persisted position is within any connected screen's visible frame
        let onScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.contains(point)
        }
        if onScreen {
            return point
        }

        return Self.defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
    }

    /// Save current origin to UserDefaults.
    /// Note: internal (not private) to allow direct test access from
    /// TestFloatingPill.swift, which compiles in the same module.
    func savePosition() {
        let origin = frame.origin
        let value = "\(origin.x),\(origin.y)"
        UserDefaults.standard.set(value, forKey: Self.positionKey)
    }
}
