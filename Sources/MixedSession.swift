// Sources/MixedSession.swift
// Magpie — Mic + system audio as dual independent streams into one CAF file.
//
// Architecture (dual-stream, no mixer graph):
//   Mic:    engine.inputNode.installTap → writeBuffer() ──┐
//                                                          ├→ AVAudioFile (CAF)
//   System: SCStream delegate → convertToPCMBuffer() ────┘
//                               (synchronized via NSLock)
//
// Mic recording starts synchronously. System audio capture is attempted
// asynchronously — if SCStream fails, mic recording continues uninterrupted.

import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records mic + system audio as two independent streams into one CAF file.
/// After stop(), RecorderModel converts CAF→M4A before passing to Yap.
final class MixedSession: NSObject, RecordingSession, SCStreamOutput, SCStreamDelegate {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var stream: SCStream?
    let writeLock = NSLock()
    var micCallbackCount = 0
    var systemCallbackCount = 0
    private let audioQueue = DispatchQueue(label: "com.crbikebike.magpie.mixedaudio", qos: .userInteractive)

    /// Called on the main thread when system audio status changes.
    /// Set before calling start(to:).
    var onSystemAudioStatusChange: ((SystemAudioStatus) -> Void)?

    /// Set by RecorderModel before start() to enable vault logging.
    var vaultPath: URL?

    // MARK: - RecordingSession

    func start(to url: URL) throws {
        let engine = AVAudioEngine()
        self.engine = engine

        // Query the mic's native hardware format — nil-format tap avoids NSException
        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            log("Mic hardware format invalid (\(hwFormat)) — another app may have exclusive access",
                vaultPath: vaultPath)
            throw MicUnavailableError.exclusiveAccess
        }

        audioFile = try AVAudioFile(forWriting: url, settings: hwFormat.settings)
        micCallbackCount = 0

        // Pass nil as format — AVAudioEngine uses the input node's native format.
        // This eliminates the format mismatch NSException entirely.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [weak self] buf, _ in
            self?.micCallbackCount += 1
            self?.writeBuffer(buf)
        }

        try engine.start()

        // System audio capture — non-fatal. Mic recording continues if this fails.
        Task { [weak self] in
            do {
                try await self?.startSystemAudioCapture()
            } catch {
                log("System audio unavailable, recording mic only: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        if let stream {
            let s = stream
            self.stream = nil
            Task { try? await s.stopCapture() }
        }

        log("MixedSession stopping — mic callbacks: \(micCallbackCount), system callbacks: \(systemCallbackCount)", vaultPath: vaultPath)

        audioFile = nil
        micCallbackCount = 0
        systemCallbackCount = 0
    }

    func averagePowerLinear() -> Float {
        // MixedSession doesn't use AVAudioRecorder metering.
        // Level monitor not supported — return a fixed "active" signal.
        return 0.3
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcmBuffer = convertToPCMBuffer(sampleBuffer) else {
            log("convertToPCMBuffer returned nil — dropping SCStream buffer (diagnosable via log)")
            return
        }
        systemCallbackCount += 1  // diagnostic-only
        writeBuffer(pcmBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream stopped with error: \(error.localizedDescription)")
        // Mic recording continues — system audio is best-effort
    }

    // MARK: - Internal

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? audioFile?.write(from: buffer)
    }

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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let srcFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Get raw audio data from CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                  totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer else { return nil }

        // Create source buffer from CMSampleBuffer data
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: frameCount) else { return nil }
        srcBuffer.frameLength = frameCount

        if srcFormat.isInterleaved {
            // For interleaved formats floatChannelData is nil — copy the raw block
            // buffer bytes directly into the AudioBufferList's single interleaved buffer.
            guard let dest = srcBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
                return nil
            }
            memcpy(dest, dataPointer, dataLength)
        } else {
            // For non-interleaved formats the block buffer is laid out as
            // [ch0_samples][ch1_samples]…, one contiguous slice per channel.
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

        // Target format = whatever the audio file is actually using (matches mic hardware)
        guard let dstFormat = audioFile?.processingFormat else { return nil }

        // If source already matches the file's format, return directly
        if srcFormat.sampleRate == dstFormat.sampleRate
            && srcFormat.channelCount == dstFormat.channelCount {
            return srcBuffer
        }

        // Convert to the file's format using AVAudioConverter
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }
        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat,
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
