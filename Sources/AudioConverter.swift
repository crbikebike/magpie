// Sources/AudioConverter.swift
// Magpie — audio-format conversions for the transcription pipeline.
//
// SystemAudioSession and MixedSession record to CAF (AVAudioEngine writes PCM).
// After stop(), RecorderModel converts CAF→M4A for vault retention and then
// produces a throwaway 16 kHz mono PCM WAV for whisper-cli — that binary
// expects PCM WAV unless built against ffmpeg, and the Homebrew formula
// doesn't guarantee that link.

import AVFoundation
import Foundation

/// Convert CAF (PCM) to M4A (AAC) using AVAssetExportSession.
/// Throws if the export session cannot be created or if export fails.
func convertCAFtoM4A(src: URL, dst: URL) async throws {
    let asset = AVURLAsset(url: src)
    guard let session = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetAppleM4A
    ) else {
        throw NSError(
            domain: "com.crbikebike.magpie",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create export session for \(src.lastPathComponent)"]
        )
    }
    session.outputURL = dst
    session.outputFileType = .m4a
    await session.export()
    if let error = session.error { throw error }
}

/// Mix two CAF files (mic + system audio) into a single CAF, with the system
/// stream shifted forward by `systemOffsetSeconds` to compensate for the
/// SCStream start-up latency. Used by MixedSession.finalizeMix().
///
/// Uses AVAudioEngine offline manual rendering with two AVAudioPlayerNodes
/// feeding the main mixer. The mixer auto-handles sample-rate and channel-count
/// conversion between the two source formats and the chosen output format.
///
/// Output format = mic file's processing format (so the mic stream goes through
/// no resampling).
func mixDualStreamCAF(
    micURL: URL,
    systemURL: URL,
    outputURL: URL,
    systemOffsetSeconds: Double
) throws {
    let micFile = try AVAudioFile(forReading: micURL)
    let systemFile = try AVAudioFile(forReading: systemURL)

    let outputFormat = micFile.processingFormat
    let outputFileSettings = micFile.fileFormat.settings

    let engine = AVAudioEngine()
    let mixer = engine.mainMixerNode

    let micPlayer = AVAudioPlayerNode()
    let systemPlayer = AVAudioPlayerNode()
    engine.attach(micPlayer)
    engine.attach(systemPlayer)

    engine.connect(micPlayer, to: mixer, format: micFile.processingFormat)
    engine.connect(systemPlayer, to: mixer, format: systemFile.processingFormat)

    let maxFrames: AVAudioFrameCount = 4096
    try engine.enableManualRenderingMode(.offline,
                                          format: outputFormat,
                                          maximumFrameCount: maxFrames)

    try engine.start()

    micPlayer.scheduleFile(micFile, at: nil, completionHandler: nil)
    micPlayer.play()

    // Schedule system at offset relative to the engine's manual rendering clock.
    let offsetFrames = AVAudioFramePosition((systemOffsetSeconds * outputFormat.sampleRate).rounded())
    let systemStartTime = AVAudioTime(sampleTime: offsetFrames, atRate: outputFormat.sampleRate)
    systemPlayer.scheduleFile(systemFile, at: systemStartTime, completionHandler: nil)
    systemPlayer.play()

    // Project both source lengths onto the output sample rate, then take the max.
    let micFramesOut = AVAudioFramePosition(
        (Double(micFile.length) * outputFormat.sampleRate / micFile.processingFormat.sampleRate).rounded()
    )
    let systemFramesOut = AVAudioFramePosition(
        (Double(systemFile.length) * outputFormat.sampleRate / systemFile.processingFormat.sampleRate).rounded()
    )
    let totalFrames = max(micFramesOut, offsetFrames + systemFramesOut)

    let outFile = try AVAudioFile(forWriting: outputURL, settings: outputFileSettings)

    guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                              frameCapacity: maxFrames) else {
        engine.stop()
        throw NSError(domain: "com.crbikebike.magpie", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate mix render buffer"])
    }

    while engine.manualRenderingSampleTime < totalFrames {
        let remaining = totalFrames - engine.manualRenderingSampleTime
        let toRender = AVAudioFrameCount(min(Int64(maxFrames), remaining))
        let status = try engine.renderOffline(toRender, to: renderBuffer)
        switch status {
        case .success:
            try outFile.write(from: renderBuffer)
        case .insufficientDataFromInputNode, .cannotDoInCurrentContext, .error:
            engine.stop()
            return
        @unknown default:
            engine.stop()
            return
        }
    }

    engine.stop()
}

/// Convert an audio file (M4A, CAF, MP3, etc. — anything AudioToolbox decodes)
/// to a 16 kHz mono 16-bit signed PCM WAV via `/usr/bin/afconvert`. This is
/// the format whisper-cli expects. The WAV is throwaway — produced for one
/// transcription run, deleted afterwards.
///
/// Throws if afconvert exits non-zero or fails to launch.
func convertToWAV16k(src: URL, dst: URL) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    proc.arguments = [
        "-f", "WAVE",
        "-d", "LEI16@16000",
        "-c", "1",
        src.path,
        dst.path,
    ]
    let errPipe = Pipe()
    proc.standardOutput = Pipe()
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let stderr = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw NSError(
            domain: "com.crbikebike.magpie",
            code: Int(proc.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey:
                "afconvert exit \(proc.terminationStatus)\(stderr.isEmpty ? "" : ": \(stderr)")"]
        )
    }
}
