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
