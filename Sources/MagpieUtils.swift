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

// MARK: - Filename slug

/// Slugify a (possibly nil/empty) title into a filesystem-safe filename stem.
///
/// Steps: trim → lowercase → replace any run of non-[a-z0-9] with a single
/// hyphen → strip leading/trailing hyphens → truncate to 60 chars.
/// Returns `"recording"` for nil/empty input or output that collapses to "".
func filenameSlug(for title: String?) -> String {
    guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else {
        return "recording"
    }
    // Approximate ASCII transliteration — strips diacritics, normalizes
    // smart quotes etc. Then keep [a-z0-9] only.
    let ascii = raw.applyingTransform(.toLatin, reverse: false) ?? raw
    let folded = (ascii.applyingTransform(.stripDiacritics, reverse: false) ?? ascii)
        .lowercased()

    var out = ""
    out.reserveCapacity(folded.count)
    var lastWasHyphen = false
    for ch in folded {
        if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
            out.append(ch)
            lastWasHyphen = false
        } else {
            if !lastWasHyphen && !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
    }
    // Trim trailing hyphen if the title ended with non-alphanumerics.
    while out.hasSuffix("-") { out.removeLast() }
    if out.isEmpty { return "recording" }
    if out.count > 60 {
        out = String(out.prefix(60))
        while out.hasSuffix("-") { out.removeLast() }
    }
    return out
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
///   - title: Optional meeting title — used both as the H1 heading and as
///            the filename slug. When nil the filename uses the historical
///            `-recording.md` suffix.
/// - Returns: URL of the written file.
@discardableResult
func writeMarkdown(
    transcript: String,
    vault: URL,
    durationSeconds: Int,
    now: Date = Date(),
    title: String? = nil
) throws -> URL {
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

    let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let h1: String
    if let heading, !heading.isEmpty {
        h1 = "# \(heading) — \(dateStr) \(timeStr)"
    } else {
        h1 = "# Recording — \(dateStr) \(timeStr)"
    }

    let content = """
    \(h1)

    **Date:** \(dateStr)
    **Time:** \(timeStr)
    **Duration:** \(durationStr)

    ## Transcript

    \(transcript)
    """

    let slug = filenameSlug(for: title)
    // Preserve the historical default ("-recording") when no title given.
    let filenameStem = (title == nil) ? "recording" : slug
    let filename = "\(dateStr)-\(timeSlug)-\(filenameStem).md"
    let url = dir.appendingPathComponent(filename)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
