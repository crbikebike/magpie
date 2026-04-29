// Sources/SystemAudioSession.swift
// Aperture — System audio capture via ScreenCaptureKit.
//
// Requires macOS 14.4+ and "Screen & System Audio Recording" TCC permission.
// SCStream with capturesAudio=true delivers CMSampleBuffers directly to AVAudioFile.
//
// start() blocks via DispatchSemaphore until SCStream.startCapture() resolves —
// system-only mode has no mic fallback, failure must be visible immediately.

import AVFoundation
import Foundation
import ScreenCaptureKit

/// System audio capture via ScreenCaptureKit.
/// Requires macOS 14.4+ and "Screen & System Audio Recording" TCC permission.
final class SystemAudioSession: NSObject, RecordingSession {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private let audioQueue = DispatchQueue(label: "com.crbikebike.magpie.sysaudio", qos: .userInteractive)
    private var isCapturing = false

    /// Called on the main thread when system audio status changes after start().
    /// Set before calling start(to:).
    var onSystemAudioStatusChange: ((SystemAudioStatus) -> Void)?

    // MARK: - Permission Management

    /// UserDefaults key persisting the last-known TCC grant state.
    /// TCC probing is unreliable — UserDefaults is the only stable signal.
    static let permissionGrantedKey = "sysAudioPermissionGranted"

    enum Permission { case notDetermined, authorized, denied }

    /// Probe current permission state from UserDefaults.
    static func currentPermission() -> Permission {
        UserDefaults.standard.bool(forKey: permissionGrantedKey) ? .authorized : .notDetermined
    }

    /// Trigger macOS TCC prompt via SCShareableContent. Persists result to UserDefaults.
    /// Returns the resolved permission.
    ///
    /// Runs the async SCShareableContent call on a background queue to avoid
    /// deadlocking the main thread (Task + semaphore on main = deadlock).
    @discardableResult
    static func requestPermission() -> Permission {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Permission = .denied

        // Must dispatch to a background queue — SCShareableContent is async and
        // the semaphore would deadlock if waited on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            group.enter()
            Task {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    UserDefaults.standard.set(true, forKey: permissionGrantedKey)
                    result = .authorized
                } catch {
                    result = .denied
                }
                group.leave()
            }
            group.wait()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    // MARK: - RecordingSession

    /// Start capturing system audio, writing to `url` (CAF format).
    /// Blocks until SCStream starts or throws — no silent fallback.
    func start(to url: URL) throws {
        let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        audioFile = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    throw NSError(domain: "Aperture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No display found for system audio capture"])
                }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                // Audio-only capture — minimise video overhead.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimum

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                try await stream.startCapture()

                self.stream = stream
                self.isCapturing = true
                UserDefaults.standard.set(true, forKey: SystemAudioSession.permissionGrantedKey)
            } catch {
                startError = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let error = startError {
            audioFile = nil
            throw error
        }
    }

    func stop() {
        guard let stream = stream else {
            audioFile = nil
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await stream.stopCapture()
            semaphore.signal()
        }
        semaphore.wait()

        self.stream = nil
        self.audioFile = nil
        self.isCapturing = false
    }

    func averagePowerLinear() -> Float {
        // System audio doesn't expose power metering via AVAudioRecorder.
        // Return a constant "active" level when the stream is running.
        return isCapturing ? 0.3 : 0
    }
}

// MARK: - SCStreamOutput

extension SystemAudioSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let audioFile = self.audioFile else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame
        guard sampleRate > 0, channels > 0 else { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        let srcFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        )!
        let dstFormat = audioFile.processingFormat

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        srcBuffer.frameLength = AVAudioFrameCount(frameCount)

        var length = 0
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: nil)

        // Copy data from CMBlockBuffer to PCM buffer
        if let srcChannels = srcBuffer.floatChannelData {
            let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0, length >= frameCount * bytesPerFrame else { return }

            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPtr)
            guard let rawPtr = dataPtr else { return }

            let floatPtr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float32.self)
            let isInterleaved = channels > 1 && asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

            if isInterleaved {
                let chCount = Int(channels)
                for ch in 0..<min(chCount, Int(srcFormat.channelCount)) {
                    let dst = srcChannels[ch]
                    for frame in 0..<frameCount {
                        dst[frame] = floatPtr[frame * chCount + ch]
                    }
                }
            } else {
                let framesPerChannel = frameCount
                for ch in 0..<Int(srcFormat.channelCount) {
                    let dst = srcChannels[ch]
                    let offset = ch * framesPerChannel
                    for frame in 0..<framesPerChannel {
                        dst[frame] = floatPtr[offset + frame]
                    }
                }
            }
        }

        // If sample rates and channel counts match, write directly; otherwise convert.
        if srcFormat.sampleRate == dstFormat.sampleRate && srcFormat.channelCount == dstFormat.channelCount {
            try? audioFile.write(from: srcBuffer)
        } else {
            // Use AVAudioConverter for sample rate / channel count mismatch
            guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return }
            let ratio = dstFormat.sampleRate / srcFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(frameCount) * ratio)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outFrames) else { return }

            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .haveData
                return srcBuffer
            }
            if convError == nil {
                try? audioFile.write(from: outBuffer)
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)")
        isCapturing = false
    }
}
