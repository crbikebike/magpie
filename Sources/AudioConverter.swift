// Sources/AudioConverter.swift
// Magpie — CAF-to-M4A conversion for system audio recordings.
//
// SystemAudioSession and MixedSession record to CAF (AVAudioEngine writes PCM).
// After stop(), RecorderModel converts CAF→M4A before passing to Yap.

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
