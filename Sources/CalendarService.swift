// Sources/CalendarService.swift
// Magpie — Fetches upcoming calendar events via the Claude.ai Google Calendar
// connector.
//
// Architecture:
//   - Spawns `claude -p "<strict JSON prompt>"` as a subprocess.
//   - The connector's `mcp__claude_ai_Google_Calendar__*` tools live inside the
//     user's signed-in Claude.ai account — no separate MCP install required.
//   - `--allowedTools` is passed so the connector tools don't trigger an
//     interactive permission prompt on every 15-minute poll. This is the
//     single biggest implementation unknown — verify the flag name on the
//     target Claude Code build during smoke testing.
//   - JSON is parsed with the same three-stage extraction used by
//     `bin/watcher.py:_extract_json` (direct, code-fence-stripped, balanced
//     brace) so the model's output format doesn't have to be exact.
//   - On any error path `consecutiveFailures` increments — the menubar amber
//     dot turns on at ≥ 3.

import Combine
import Foundation

// MARK: - Errors

enum CalendarServiceError: Error, LocalizedError {
    /// `claude` binary not found in any known PATH location.
    case binaryNotFound
    /// Subprocess exited non-zero. `stderr` is the captured tail (≤ 2 KB).
    case subprocessFailed(exitCode: Int32, stderr: String)
    /// 15-second timeout elapsed before subprocess returned.
    case timeout
    /// Output didn't contain parseable JSON in any of the three extraction stages.
    case jsonParseFailed(rawPreview: String)
    /// Strict-JSON envelope didn't decode into `CalendarFetchResponse`.
    case schemaMismatch(detail: String)
    /// Connector reported an auth error in stderr / output (signed-out, not authorized).
    case notAuthorized(hint: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:           return "claude CLI not found on this system"
        case .subprocessFailed(let c, let s):
                                        return "claude exited \(c): \(s)"
        case .timeout:                  return "claude calendar fetch timed out after 15s"
        case .jsonParseFailed(let p):   return "calendar fetch returned non-JSON output: \(p)"
        case .schemaMismatch(let d):    return "calendar JSON did not match schema: \(d)"
        case .notAuthorized(let h):     return "Google Calendar connector not authorized: \(h)"
        }
    }
}

// MARK: - Service

final class CalendarService: ObservableObject, @unchecked Sendable {

    /// Number of consecutive failed fetches. Drives the menubar amber dot.
    /// Resets to 0 on the next success.
    @Published var consecutiveFailures: Int = 0

    /// Timestamp of the most recent successful fetch (used by UI for the
    /// "last fetched X min ago" hint in preferences).
    @Published var lastSuccessfulFetch: Date? = nil

    /// Filtered upcoming events from the most recent successful fetch — the
    /// same set the scheduler would prompt for (see
    /// `CalendarEvent.passesAlertFilters`). Drives the menubar's Upcoming
    /// section so the user can confirm what Magpie has actually downloaded.
    @Published var upcomingEvents: [CalendarEvent] = []

    /// Most recent fetch error, cleared on the next success. Drives the
    /// inline error chip in the menubar's Upcoming section.
    @Published var lastFetchError: CalendarServiceError? = nil

    /// Strict JSON prompt — see CalendarFetchResponse for the contract.
    private static let prompt = """
    Use the Google Calendar connector to list events with start times \
    between now and 4 hours from now (inclusive). Across all calendars the \
    user has authorized.

    Return ONLY a single JSON object — no prose, no markdown, no code fences. \
    Match this exact shape:

    {
      "events": [
        {
          "id": "iCalUID or event id",
          "title": "summary text or empty string",
          "start": "ISO8601 datetime with timezone offset",
          "end": "ISO8601 datetime with timezone offset",
          "status": "accepted | declined | tentative | needsAction",
          "calendar": "calendar display name",
          "allDay": false
        }
      ],
      "fetched_at": "ISO8601 datetime with timezone offset"
    }

    If there are no events in the window, return \
    {"events": [], "fetched_at": "..."}.

    Treat the user's own response status as the "status" field. If unknown, \
    use "accepted". For all-day events set allDay to true and use date-only \
    start/end at midnight local time.
    """

    /// PATH locations to search for the `claude` binary, in priority order.
    /// Includes ~/.local/bin (npm global default) and ~/.npm-global/bin.
    private static var claudePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.nvm/versions/node/current/bin/claude",
        ]
    }

    /// 60s — first call cold-starts the model + may roundtrip to Google.
    /// Polling fetches are usually <5s once warm.
    private static let subprocessTimeout: TimeInterval = 60

    // MARK: - Public API

    /// Fetch events in the next 4 hours.
    ///
    /// Throws on subprocess failure, timeout, JSON parse failure, or schema
    /// mismatch. Side effect: increments `consecutiveFailures` on throw,
    /// resets it on return.
    @discardableResult
    func fetchUpcomingEvents() async throws -> [CalendarEvent] {
        do {
            let output = try await spawnClaude(prompt: Self.prompt)
            let response = try decode(output: output)
            let now = Date()
            let filtered = response.events.filter { $0.passesAlertFilters(now: now) }
                .sorted { $0.start < $1.start }
            await MainActor.run {
                self.consecutiveFailures = 0
                self.lastSuccessfulFetch = now
                self.upcomingEvents = filtered
                self.lastFetchError = nil
            }
            return response.events
        } catch {
            let svcError: CalendarServiceError
            if let e = error as? CalendarServiceError {
                svcError = e
            } else {
                svcError = .subprocessFailed(exitCode: -1, stderr: error.localizedDescription)
            }
            await MainActor.run {
                self.consecutiveFailures += 1
                self.lastFetchError = svcError
            }
            throw error
        }
    }

    /// Probe used by onboarding to distinguish auth states from connectivity errors.
    /// Returns `.success` with event count on success, otherwise the specific failure mode.
    func probeForOnboarding() async -> ProbeResult {
        do {
            let events = try await fetchUpcomingEvents()
            return .success(eventCount: events.count)
        } catch CalendarServiceError.binaryNotFound {
            return .signedOutOrMissing
        } catch CalendarServiceError.notAuthorized(let hint) {
            return .notAuthorized(hint: hint)
        } catch let CalendarServiceError.subprocessFailed(_, stderr)
            where stderr.lowercased().contains("login")
                || stderr.lowercased().contains("auth")
                || stderr.lowercased().contains("sign in") {
            return .signedOutOrMissing
        } catch {
            return .otherFailure(detail: error.localizedDescription)
        }
    }

    enum ProbeResult {
        case success(eventCount: Int)
        case signedOutOrMissing
        case notAuthorized(hint: String)
        case otherFailure(detail: String)
    }

    // MARK: - Subprocess

    /// Resolved tooling — claude's absolute path + the PATH env to give it
    /// (so claude can find its `node` interpreter). Resolved once via a
    /// login-shell `command -v` lookup, then cached for the lifetime of the
    /// app so we don't re-source zshrc/zprofile on every fetch (which is
    /// what caused TCC permission prompts to appear for user folders that
    /// the user's shell config happens to touch).
    private struct Tooling {
        let claudePath: String
        let pathEnv: String
    }
    private static var cachedTooling: Tooling?
    private static let cacheLock = NSLock()

    /// Empty, private directory used as the spawned `claude`'s cwd. Without
    /// this the subprocess inherits Magpie's launch cwd (typically `/` when
    /// launched from Finder) and claude's startup project-context walk
    /// touches Downloads / Documents / Volumes — each one a TCC dialog
    /// attributed to Magpie. See issue #8.
    private static let privateCwd: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Magpie", isDirectory: true)
            .appendingPathComponent("calendar-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Invoke `claude -p "<prompt>"` with --allowedTools restricted to the
    /// Google Calendar connector. Captures stdout (the JSON) and stderr (for
    /// error diagnosis). Times out at 60s (cold start can be 20–40s).
    ///
    /// First-call only: spawns a login shell to resolve claude's path and
    /// PATH from the user's shell config. Cached after that. Subsequent
    /// fetches spawn claude directly with the cached env — no shell sourcing,
    /// no spurious TCC prompts.
    private func spawnClaude(prompt: String) async throws -> String {
        let tooling = try await resolveTooling()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tooling.claudePath)
            proc.currentDirectoryURL = Self.privateCwd
            proc.arguments = [
                "-p", prompt,
                "--output-format", "text",
                "--allowedTools", "mcp__claude_ai_Google_Calendar__*",
            ]
            // Minimal env: PATH (so claude can find node), HOME (so claude
            // can find ~/.claude/), USER, TMPDIR. Everything else stripped
            // — fewer attack surfaces for TCC prompts via tooling that
            // probes weird directories.
            var env: [String: String] = [
                "PATH": tooling.pathEnv,
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
            ]
            if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
                env["TMPDIR"] = tmp
            }
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice

            var didResume = false
            let resumeLock = NSLock()
            func resumeOnce(_ result: Result<String, Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let s): cont.resume(returning: s)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            // Watchdog — kill the process if it doesn't return in time.
            let timeoutWork = DispatchWorkItem {
                if proc.isRunning {
                    proc.terminate()
                    // SIGTERM may not land instantly on hung subprocesses;
                    // give it 1s then SIGKILL.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                    }
                }
                resumeOnce(.failure(CalendarServiceError.timeout))
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Self.subprocessTimeout,
                execute: timeoutWork
            )

            proc.terminationHandler = { p in
                timeoutWork.cancel()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                if p.terminationStatus == 0 {
                    // The connector occasionally writes auth hints to stderr
                    // even on exit 0. Surface those as `.notAuthorized` so
                    // onboarding can branch correctly.
                    let lower = stderr.lowercased()
                    if lower.contains("not authorized")
                        || lower.contains("connector")
                            && (lower.contains("authorize") || lower.contains("permission")) {
                        resumeOnce(.failure(CalendarServiceError.notAuthorized(
                            hint: String(stderr.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                        )))
                        return
                    }
                    resumeOnce(.success(stdout))
                } else {
                    let trimmed = String(stderr.prefix(2048))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    resumeOnce(.failure(CalendarServiceError.subprocessFailed(
                        exitCode: p.terminationStatus,
                        stderr: trimmed
                    )))
                }
            }

            do {
                try proc.run()
            } catch {
                timeoutWork.cancel()
                resumeOnce(.failure(error))
            }
        }
    }

    // MARK: - Tooling resolution

    /// Return cached tooling or resolve it.
    ///
    /// Resolution order:
    ///   1. Cache hit → return it.
    ///   2. Walk hardcoded paths (homebrew, ~/.local/bin, etc.). For each
    ///      executable candidate, run `--version` under the same locked-down
    ///      env we'd use for real fetches and skip ones that fail. Cache and
    ///      return the first that passes.
    ///   3. Fall back to a `$SHELL -l -c` lookup that prints both
    ///      `command -v claude` and `$PATH`. Verify it the same way.
    ///   4. None of the above → `.binaryNotFound`.
    private func resolveTooling() async throws -> Tooling {
        if let cached = Self.read(cache: { $0 }) { return cached }

        // Walk the hardcoded paths, but actually invoke each candidate with
        // `--version` under our locked-down env before caching. Skips wrapper
        // shims that work in the user's interactive shell but fail under the
        // PATH we hand subprocesses (the bug that masked ~/.local/bin/claude
        // behind a broken /opt/homebrew/bin/claude wrapper).
        for path in Self.claudePaths where FileManager.default.isExecutableFile(atPath: path) {
            if Self.looksLikeShellWrapper(at: path) {
                log("CalendarService: candidate \(path) looks like a shell-sourcing wrapper, skipping without invoking")
                continue
            }
            let dir = (path as NSString).deletingLastPathComponent
            let pathEnv = [
                dir,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ].joined(separator: ":")
            let candidate = Tooling(claudePath: path, pathEnv: pathEnv)
            if await verify(candidate) {
                Self.write(cache: candidate)
                return candidate
            }
            log("CalendarService: candidate \(path) failed --version probe, skipping")
        }

        // Last resort — login-shell lookup. Verify it too: the shell's
        // `command -v` can resolve to the same broken wrapper. Skip if the
        // resolved path is itself a shell wrapper.
        if let resolved = await shellResolveTooling(),
           !Self.looksLikeShellWrapper(at: resolved.claudePath),
           await verify(resolved) {
            Self.write(cache: resolved)
            return resolved
        }

        throw CalendarServiceError.binaryNotFound
    }

    /// Inspect a candidate's shebang. Returns true if the file is a shell
    /// script whose interpreter would source the user's rc files (which can
    /// touch arbitrary user folders and trip TCC dialogs attributed to
    /// Magpie). Skipping these without invoking is the only way to keep the
    /// first launch quiet on a freshly-reinstalled bundle.
    ///
    /// Heuristic: shebang line contains "zsh" anywhere (zsh sources zshenv
    /// even non-interactively in many distros), or contains a login (`-l`)
    /// or interactive (`-i`) flag for any shell.
    private static func looksLikeShellWrapper(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 256),
              let head = String(data: data, encoding: .utf8),
              head.hasPrefix("#!")
        else { return false }
        let firstLine = head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? head
        let lower = firstLine.lowercased()
        if lower.contains("zsh") { return true }
        // Match `-l` or `-i` as standalone flags (avoid matching e.g. "-list").
        if lower.range(of: #"(?<![a-z0-9])-[li](?![a-z0-9])"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Run `<claudePath> --version` under the same env we'd use for real
    /// fetches. Returns true iff exit 0 within 5s.
    private func verify(_ tooling: Tooling) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tooling.claudePath)
            proc.currentDirectoryURL = Self.privateCwd
            proc.arguments = ["--version"]
            proc.environment = [
                "PATH": tooling.pathEnv,
                "HOME": NSHomeDirectory(),
                "USER": NSUserName(),
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice

            var resumed = false
            let lock = NSLock()
            func resume(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: ok)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if proc.isRunning { proc.terminate() }
                resume(false)
            }
            proc.terminationHandler = { p in resume(p.terminationStatus == 0) }
            do { try proc.run() } catch { resume(false) }
        }
    }

    private static func read<T>(cache: (Tooling) -> T) -> T? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cachedTooling.map(cache)
    }

    private static func write(cache value: Tooling) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedTooling = value
    }

    /// One-time login-shell lookup. Returns nil if shell can't be invoked or
    /// claude isn't on the user's PATH.
    private func shellResolveTooling() async -> Tooling? {
        await withCheckedContinuation { (cont: CheckedContinuation<Tooling?, Never>) in
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            // Single line of stdout: "<claude-path>|<PATH>"
            proc.arguments = ["-l", "-c", #"printf '%s|%s\n' "$(command -v claude)" "$PATH""#]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice

            var resumed = false
            let lock = NSLock()
            func resume(_ v: Tooling?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: v)
            }

            // 5s cap — login shell should resolve fast.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if proc.isRunning { proc.terminate() }
                resume(nil)
            }

            proc.terminationHandler = { _ in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                guard let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty
                else { resume(nil); return }
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { resume(nil); return }
                let path = String(parts[0])
                let pathEnv = String(parts[1])
                guard !path.isEmpty,
                      FileManager.default.isExecutableFile(atPath: path)
                else { resume(nil); return }
                resume(Tooling(claudePath: path, pathEnv: pathEnv))
            }

            do { try proc.run() } catch { resume(nil) }
        }
    }

    // MARK: - JSON extraction (three-stage, mirrors watcher.py)

    /// Try to decode the strict envelope from `output`. Three stages:
    ///   1. Direct parse
    ///   2. Code-fence stripped parse (```json ... ``` blocks)
    ///   3. Balanced-brace extraction (find outermost {...})
    private func decode(output: String) throws -> CalendarFetchResponse {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = Self.decoder

        // Stage 1: direct.
        if let data = trimmed.data(using: .utf8),
           let resp = try? decoder.decode(CalendarFetchResponse.self, from: data) {
            return resp
        }

        // Stage 2: code fences.
        if let fenced = Self.codeFenceContent(in: trimmed),
           let data = fenced.data(using: .utf8),
           let resp = try? decoder.decode(CalendarFetchResponse.self, from: data) {
            return resp
        }

        // Stage 3: balanced braces.
        if let braced = Self.balancedBraceContent(in: trimmed),
           let data = braced.data(using: .utf8) {
            do {
                return try decoder.decode(CalendarFetchResponse.self, from: data)
            } catch let DecodingError.dataCorrupted(ctx) {
                throw CalendarServiceError.schemaMismatch(detail: ctx.debugDescription)
            } catch let DecodingError.keyNotFound(key, _) {
                throw CalendarServiceError.schemaMismatch(detail: "missing key: \(key.stringValue)")
            } catch let DecodingError.typeMismatch(_, ctx) {
                throw CalendarServiceError.schemaMismatch(detail: "type mismatch: \(ctx.debugDescription)")
            } catch let DecodingError.valueNotFound(_, ctx) {
                throw CalendarServiceError.schemaMismatch(detail: "value not found: \(ctx.debugDescription)")
            }
        }

        let preview = String(trimmed.prefix(200))
            .replacingOccurrences(of: "\n", with: "\\n")
        throw CalendarServiceError.jsonParseFailed(rawPreview: preview)
    }

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // Try full ISO8601 with timezone, then with fractional seconds,
            // then date-only (for all-day events).
            let isoFull = ISO8601DateFormatter()
            isoFull.formatOptions = [.withInternetDateTime]
            if let d = isoFull.date(from: raw) { return d }
            isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFull.date(from: raw) { return d }
            let dateOnly = DateFormatter()
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = TimeZone.current
            dateOnly.dateFormat = "yyyy-MM-dd"
            if let d = dateOnly.date(from: raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unparseable date: \(raw)"
            )
        }
        return dec
    }()

    private static func codeFenceContent(in text: String) -> String? {
        // ```json\n...\n``` or ```\n...\n```
        let pattern = #"```(?:json)?\s*\n([\s\S]*?)\n\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = match, m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func balancedBraceContent(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...i])
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
