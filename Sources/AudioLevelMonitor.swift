// Sources/AudioLevelMonitor.swift
// Aperture — Timer-based audio level polling.
//
// Polls a RecordingSession's averagePowerLinear() on a repeating timer and
// delivers the result to a callback on the main queue.
//
// This keeps all UI state updates off the audio render thread entirely —
// the render thread never touches DispatchQueue.main or any @Published property.

import Foundation

final class AudioLevelMonitor {
    private var timer: Timer?
    private let interval: TimeInterval
    private let session: RecordingSession
    private let handler: (Float) -> Void

    /// - Parameters:
    ///   - session: The recording session to query.
    ///   - interval: Poll interval in seconds. Default 80 ms matches human persistence of vision.
    ///   - handler: Called on the main queue with the latest normalised level (0..1).
    init(session: RecordingSession, interval: TimeInterval = 0.08, handler: @escaping (Float) -> Void) {
        self.session = session
        self.interval = interval
        self.handler = handler
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.session.averagePowerLinear()
            DispatchQueue.main.async { self.handler(level) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
