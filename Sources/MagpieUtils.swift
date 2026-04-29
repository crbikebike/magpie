// Sources/MagpieUtils.swift
// Magpie — Pure utility functions (Foundation only, no AppKit/AVFoundation)
//
// Compile alone for tests:
//   swift test

import Foundation

// MARK: - Logger

/// Append a timestamped log line to console and optionally to inbox/logs/.
func log(_ message: String, vaultPath: URL? = nil) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    print(line, terminator: "")

    guard let vault = vaultPath else { return }
    let logDir = vault.appendingPathComponent("inbox/logs")
    let logFile = logDir.appendingPathComponent("magpie.log")
    do {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: logFile.path),
           let fh = try? FileHandle(forWritingTo: logFile) {
            fh.seekToEndOfFile()
            if let data = line.data(using: .utf8) { fh.write(data) }
            try? fh.close()
        } else {
            try line.write(to: logFile, atomically: false, encoding: .utf8)
        }
    } catch {
        print("[\(stamp)] log write failed: \(error.localizedDescription)\n", terminator: "")
    }
}

// MARK: - Executable Discovery

/// Return the first path in well-known bin directories where `name` is executable.
func findExecutable(_ name: String) -> String? {
    ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - Duration Formatting

/// Format an integer number of seconds as "Xs" or "Xm Ys".
func formatDuration(_ seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
}

// MARK: - Markdown Output

/// Write a structured recording markdown file to vault/.
///
/// - Parameters:
///   - transcript: Raw transcript text from Yap.
///   - vault: Root URL of the Magpie vault.
///   - durationSeconds: Recording length in seconds.
///   - now: Timestamp to use for filename and headers (default: current time).
///           Pass a fixed value in tests for deterministic output.
/// - Returns: URL of the written file.
@discardableResult
func writeMarkdown(transcript: String, vault: URL, durationSeconds: Int, now: Date = Date()) throws -> URL {
    let dir = vault
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")

    df.dateFormat = "yyyy-MM-dd"
    let dateStr = df.string(from: now)

    df.dateFormat = "HH:mm:ss"
    let timeStr = df.string(from: now)

    df.dateFormat = "HHmmss"
    let timeSlug = df.string(from: now)

    let durationStr = formatDuration(durationSeconds)

    let content = """
    # Recording — \(dateStr) \(timeStr)

    **Date:** \(dateStr)
    **Time:** \(timeStr)
    **Duration:** \(durationStr)

    ## Transcript

    \(transcript)
    """

    let filename = "\(dateStr)-\(timeSlug)-recording.md"
    let url = dir.appendingPathComponent(filename)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
