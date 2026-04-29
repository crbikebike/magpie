// Sources/MicSession.swift
// Magpie — Microphone capture session using AVAudioRecorder.
//
// AVAudioRecorder is the correct API for mic-only recording:
//   • Handles hardware format negotiation internally
//   • Writes to file off the audio render thread
//   • Built-in metering via averagePower(forChannel:)
//
// Records directly to M4A/AAC — no post-recording CAF→M4A conversion needed.

import AVFoundation
import Foundation

// MARK: - RecordingSession Protocol

/// Abstraction over mic recording — enables mock-based unit tests without hardware.
protocol RecordingSession: AnyObject {
    /// Start recording to the given URL.
    func start(to url: URL) throws
    /// Stop recording and flush the file.
    func stop()
    /// Instantaneous average power on channel 0, normalized 0..1.
    /// Must be called on a polling timer, not the audio render thread.
    func averagePowerLinear() -> Float
}

// MARK: - MicSession

/// AVAudioRecorder-based microphone capture.
/// Records M4A/AAC directly — passes the output URL straight to Yap.
final class MicSession: NSObject, RecordingSession {
    private var recorder: AVAudioRecorder?

    func start(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        rec.delegate = self
        guard rec.record() else {
            throw MicSessionError.recordDidNotStart
        }
        recorder = rec
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }

    func averagePowerLinear() -> Float {
        guard let rec = recorder, rec.isRecording else { return 0 }
        rec.updateMeters()
        // dBFS: -160 (silence) to 0 (max).  Normalise to 0..1 over a –80 dB window.
        let dB = rec.averagePower(forChannel: 0)
        return max(0, min((dB + 80) / 80, 1))
    }
}

extension MicSession: AVAudioRecorderDelegate {
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error {
            log("MicSession encode error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum MicSessionError: Error, LocalizedError {
    case recordDidNotStart

    var errorDescription: String? {
        switch self {
        case .recordDidNotStart:
            return "AVAudioRecorder.record() returned false — check microphone permission"
        }
    }
}
