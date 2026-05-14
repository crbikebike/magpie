// Sources/MixedSession.swift
// Magpie — Mic + system audio recorded as two independent CAF files,
// then mixed into one CAF in finalizeMix() after stop().
//
// Architecture (dual-file, post-mix):
//   Mic:    engine.inputNode.installTap → mic.caf
//   System: SCStream delegate           → system.caf
//   finalizeMix(): mic.caf + system.caf → output.caf (AVAudioEngine offline render)
//
// Why two files instead of one:
//   AVAudioFile.write(from:) is append-only — both producers writing to one
//   file produced a file whose duration was the SUM of both streams, which
//   played back at ~0.5× speed with audible chop as buffers interleaved.
//
// Mic recording starts synchronously. System audio capture is attempted
// asynchronously — if SCStream fails, mic recording continues uninterrupted
// and finalizeMix() falls back to renaming mic.caf into the output URL.

import AVFoundation
import Darwin
import Foundation
import ScreenCaptureKit

/// Records mic + system audio as two independent streams into two CAF files,
/// mixed together in finalizeMix() after stop().
final class MixedSession: NSObject, RecordingSession, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var stream: SCStream?

    var micCallbackCount = 0
    var systemCallbackCount = 0
    private let audioQueue = DispatchQueue(label: "com.crbikebike.magpie.mixedaudio", qos: .userInteractive)

    /// Wall-clock anchors used to align system audio against mic during the mix.
    /// SCStream starts asynchronously and its first buffer arrives some hundreds of
    /// milliseconds after the mic — without this offset the two streams would be
    /// misaligned in the final mix.
    private var micStartHostTime: UInt64 = 0
    private var systemFirstBufferHostTime: UInt64 = 0

    /// Final output URL (the one RecorderModel handed us). Mix is written here.
    private var outputURL: URL?
    /// Temp file for mic-only audio, sibling of outputURL.
    private var micURL: URL?
    /// Temp file for system-only audio, sibling of outputURL.
    private var systemURL: URL?

    /// System file is always 48 kHz mono — matches SCStreamConfiguration below.
    private let systemFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    /// Called on the main thread when system audio status changes.
    /// Set before calling start(to:).
    var onSystemAudioStatusChange: ((SystemAudioStatus) -> Void)?

    /// Set by RecorderModel before start() to enable vault logging.
    var vaultPath: URL?

    // MARK: - RecordingSession

    func start(to url: URL) throws {
        outputURL = url
        let base = url.deletingPathExtension()
        let micPath = base.appendingPathExtension("mic.caf")
        let systemPath = base.appendingPathExtension("system.caf")
        micURL = micPath
        systemURL = systemPath

        let engine = AVAudioEngine()
        self.engine = engine

        // Query the mic's native hardware format — nil-format tap avoids NSException
        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            log("Mic hardware format invalid (\(hwFormat)) — another app may have exclusive access",
                vaultPath: vaultPath)
            throw MicUnavailableError.exclusiveAccess
        }

        micFile = try AVAudioFile(forWriting: micPath, settings: hwFormat.settings)
        micCallbackCount = 0
        systemCallbackCount = 0
        systemFirstBufferHostTime = 0

        // Pass nil as format — AVAudioEngine uses the input node's native format.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [weak self] buf, _ in
            guard let self else { return }
            self.micCallbackCount += 1
            try? self.micFile?.write(from: buf)
        }

        try engine.start()
        micStartHostTime = mach_absolute_time()

        // System audio capture — non-fatal. Mic recording continues if this fails.
        Task { [weak self] in
            do {
                try await self?.startSystemAudioCapture()
            } catch {
                log("System audio unavailable, recording mic only: \(error.localizedDescription)",
                    vaultPath: self?.vaultPath)
            }
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        // Stop SCStream synchronously so no late callbacks write to systemFile
        // after we null it out below.
        if let stream {
            let s = stream
            self.stream = nil
            let sem = DispatchSemaphore(value: 0)
            Task {
                try? await s.stopCapture()
                sem.signal()
            }
            sem.wait()
        }

        log("MixedSession stopping — mic callbacks: \(micCallbackCount), system callbacks: \(systemCallbackCount)",
            vaultPath: vaultPath)

        micFile = nil
        systemFile = nil
    }

    func averagePowerLinear() -> Float {
        // MixedSession doesn't use AVAudioRecorder metering.
        // Level monitor not supported — return a fixed "active" signal.
        return 0.3
    }

    // MARK: - Finalize (post-stop mix)

    /// Mix mic.caf + system.caf into outputURL. Call after stop().
    /// Falls back to renaming mic.caf into outputURL if no system audio was captured.
    /// Cleans up the per-stream temp files on success. Returns the final output URL.
    func finalizeMix() async throws -> URL {
        guard let outputURL, let micURL else {
            throw NSError(domain: "com.crbikebike.magpie", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "finalizeMix called before start"])
        }

        let hasSystem = systemCallbackCount > 0
            && systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        // Remove any existing file at outputURL (defensive).
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        if !hasSystem {
            log("Mix: no system audio captured — using mic-only file as final output",
                vaultPath: vaultPath)
            try FileManager.default.moveItem(at: micURL, to: outputURL)
            // No system file to clean up (either doesn't exist or is empty).
            if let systemURL,
               FileManager.default.fileExists(atPath: systemURL.path) {
                try? FileManager.default.removeItem(at: systemURL)
            }
            return outputURL
        }

        guard let systemURL else {
            throw NSError(domain: "com.crbikebike.magpie", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "system URL missing"])
        }

        let offsetSeconds = max(0, hostTimeDiffSeconds(from: micStartHostTime,
                                                       to: systemFirstBufferHostTime))
        log("Mix: starting offline render — offset=\(String(format: "%.3f", offsetSeconds))s, mic=\(micCallbackCount), sys=\(systemCallbackCount)",
            vaultPath: vaultPath)

        do {
            try mixDualStreamCAF(
                micURL: micURL,
                systemURL: systemURL,
                outputURL: outputURL,
                systemOffsetSeconds: offsetSeconds
            )
            // Clean up temp files
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
            return outputURL
        } catch {
            // Mix failed — never lose the mic recording. Fall back to mic-only.
            log("Mix failed (\(error.localizedDescription)) — falling back to mic-only",
                vaultPath: vaultPath)
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: micURL, to: outputURL)
            try? FileManager.default.removeItem(at: systemURL)
            return outputURL
        }
    }

    private func hostTimeDiffSeconds(from t0: UInt64, to t1: UInt64) -> Double {
        guard t0 > 0, t1 > t0 else { return 0 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = Double(t1 - t0) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000.0
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcmBuffer = convertToPCMBuffer(sampleBuffer) else {
            log("convertToPCMBuffer returned nil — dropping SCStream buffer")
            return
        }
        if systemFirstBufferHostTime == 0 {
            systemFirstBufferHostTime = mach_absolute_time()
        }
        systemCallbackCount += 1
        try? systemFile?.write(from: pcmBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)", vaultPath: vaultPath)
        // Mic recording continues — system audio is best-effort
    }

    // MARK: - Internal

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "com.crbikebike.magpie", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display found for system audio capture"])
        }

        let filter = SCContentFilter(display: display,
                                      excludingApplications: [],
                                      exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true  // don't capture our own output
        // Disable video capture to minimize overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS minimum

        // Open the system audio file before starting the stream so the first
        // delivered buffer has a destination.
        guard let systemURL else {
            throw NSError(domain: "com.crbikebike.magpie", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "system URL not set"])
        }
        systemFile = try AVAudioFile(forWriting: systemURL, settings: systemFormat.settings)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Convert an SCStream CMSampleBuffer into an AVAudioPCMBuffer in `systemFormat`.
    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let srcFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return nil }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: frameCount) else { return nil }
        srcBuffer.frameLength = frameCount

        if srcFormat.isInterleaved {
            guard let dest = srcBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
                return nil
            }
            memcpy(dest, dataPointer, dataLength)
        } else {
            guard let channelData = srcBuffer.floatChannelData else { return nil }
            let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
            let channelCount = Int(srcFormat.channelCount)
            guard dataLength >= channelCount * bytesPerChannel else { return nil }
            for ch in 0..<channelCount {
                memcpy(channelData[ch],
                       dataPointer.advanced(by: ch * bytesPerChannel),
                       bytesPerChannel)
            }
        }

        // If source already matches the system file's format, write directly.
        if srcFormat.sampleRate == systemFormat.sampleRate
            && srcFormat.channelCount == systemFormat.channelCount {
            return srcBuffer
        }

        // Convert to systemFormat using AVAudioConverter
        guard let converter = AVAudioConverter(from: srcFormat, to: systemFormat) else { return nil }
        let ratio = systemFormat.sampleRate / srcFormat.sampleRate
        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: systemFormat,
                                               frameCapacity: dstFrameCount) else { return nil }

        do {
            try converter.convert(to: dstBuffer, from: srcBuffer)
        } catch {
            return nil
        }
        return dstBuffer
    }
}

enum MicUnavailableError: Error, LocalizedError {
    case exclusiveAccess

    var errorDescription: String? {
        "Can't start recording — another app (like Zoom) may be controlling the microphone. Try again after your call ends."
    }
}
