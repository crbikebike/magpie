// Sources/FloatingPillWindow.swift
// Magpie — Floating pill window for always-visible recording controls.
//
// An NSPanel subclass that provides an independent, always-on-top recording
// indicator excluded from screen shares. Position persisted via UserDefaults.

import AppKit

final class FloatingPillWindow: NSPanel {

    // UserDefaults key for persisted position
    static let positionKey = "floatingPillOrigin"

    // Default position: top-right, 80pt from right edge, 60pt from top
    static func defaultOrigin(for screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let x = frame.maxX - 80 - 300  // 80pt from right edge, accounting for pill width
        let y = frame.maxY - 60        // 60pt from top
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
        clampToScreen()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        clampToScreen()
        savePosition()
    }

    private func clampToScreen() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) })
                  ?? NSScreen.main
                  ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let clampedX = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        let clampedY = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        guard clampedX != frame.origin.x || clampedY != frame.origin.y else { return }
        setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    /// Load persisted origin, falling back to defaultOrigin.
    /// Note: internal (not private) to allow direct test access from
    /// TestFloatingPill.swift, which compiles in the same module.
    func loadPosition() -> NSPoint {
        guard let stored = UserDefaults.standard.string(forKey: Self.positionKey) else {
            return Self.defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
        }

        let parts = stored.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return Self.defaultOrigin(for: NSScreen.main ?? NSScreen.screens[0])
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
