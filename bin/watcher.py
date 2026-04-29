#!/usr/bin/env python3
"""Transcript background watcher — auto-processes new transcripts.

Monitors an output directory for new .md files. On detection:
1. Debounce (5s after last modification)
2. Title inference via Claude Haiku (or local fallback)
3. File rename to slugified title
4. YAML header enrichment
5. Claude Haiku summary generation

Usage:
    python3 bin/watcher.py [--output /path/to/output] [--poll-interval 5]

Runs as a foreground process. Stops when the terminal session ends.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, date
from pathlib import Path
from typing import Optional


OUTPUT_DIR = Path(__file__).parent.parent
PID_PATH = OUTPUT_DIR / ".watcher.pid"
HEALTH_PATH = OUTPUT_DIR / ".watcher-health.json"

_TITLE_SOURCE = frozenset({"inferred", "filename"})
_SUMMARY_STATUS = frozenset({"complete", "pending"})

# Model for structured extraction tasks (title inference, summary generation).
# Haiku is sufficient for these — no need for Opus-level reasoning.
_EXTRACTION_MODEL = "claude-haiku-4-5-20251001"

# launchd user agent label for the transcript watcher.
_PLIST_LABEL = "com.crbikebike.magpie.watcher"

# Maximum consecutive failures before skipping a file until restart
_MAX_FAILURES = 3

# Delay between Claude CLI calls to avoid rate limits
_CLI_DELAY_SECONDS = 2

# Retry config for rate-limited extraction calls
_RETRY_DELAYS = (5, 15)  # seconds — exponential backoff, 2 retries max

# Recorder-generated filename: YYYY-MM-DD-HHMM-recording.md (legacy) or YYYY-MM-DD-HHMMSS-recording.md
_RECORDER_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}-\d{4}(?:\d{2})?-recording\.md$")

# Captures HH, MM, and optional SS components from a recorder-generated filename.
_FILENAME_TIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-(\d{2})(\d{2})(\d{2})?-recording\.md$")

# Subdirectory under inbox/ for retained M4A audio files.
AUDIO_DIR_NAME = "audio"

# Audio file extensions recognised as sidecar candidates.
_AUDIO_EXTENSIONS = frozenset({".m4a"})


def _validate_model() -> bool:
    """Startup check: verify _EXTRACTION_MODEL is reachable via Claude CLI.

    Returns True if model responds, False on any failure.
    Logs a clear warning on failure — never raises.
    """
    try:
        result = subprocess.run(
            ["claude", "--model", _EXTRACTION_MODEL, "--output-format", "text", "-p", "Reply with OK"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            print(f"[WATCHER] Model validation OK — model={_EXTRACTION_MODEL}")
            return True
        stderr_safe = result.stderr[:200].replace('\n', ' ')
        print(f"[WATCHER] MODEL VALIDATION FAILED — model={_EXTRACTION_MODEL}, "
              f"exit={result.returncode}, hint={stderr_safe}")
        return False
    except subprocess.TimeoutExpired:
        print(f"[WATCHER] MODEL VALIDATION FAILED — model={_EXTRACTION_MODEL}, error=timeout (10s)")
        return False
    except FileNotFoundError:
        print(f"[WATCHER] MODEL VALIDATION FAILED — claude CLI not found on PATH")
        return False
    except OSError as e:
        print(f"[WATCHER] MODEL VALIDATION FAILED — model={_EXTRACTION_MODEL}, error={e}")
        return False


def is_recorder_generated(filename: str) -> bool:
    """Return True if filename matches the recorder's naming convention.

    Args:
        filename: A filename (not a path), e.g. '2026-04-08-143022-recording.md'.

    Returns:
        True if the filename matches YYYY-MM-DD-HHMMSS-recording.md or
        YYYY-MM-DD-HHMM-recording.md (legacy format).
    """
    return _RECORDER_PATTERN.match(filename) is not None


def deslugify(filename_stem: str) -> str:
    """Convert a hyphenated filename stem to a title-cased title.

    Splits on hyphens, title-cases each token, joins with spaces.

    Args:
        filename_stem: Filename without extension, e.g. 'q1-planning-offsite'.

    Returns:
        Title string, e.g. 'Q1 Planning Offsite'. Returns 'Untitled' for empty input.
    """
    if not filename_stem:
        return "Untitled"
    words = filename_stem.split("-")
    return " ".join(w.title() for w in words if w) or "Untitled"


def _enrich_path_for_launchd() -> None:
    """Broaden PATH so tools like claude are findable when running under launchd.

    launchd provides a minimal PATH. nvm, volta, and npm-installed binaries are
    typically added in .zshrc (interactive shells) or .zprofile (login shells) —
    neither of which launchd sources. We try both startup modes, then fall back
    to scanning known install locations.
    """
    if shutil.which("claude"):
        return

    home = Path.home()
    shell = os.environ.get("SHELL") or "/bin/zsh"
    env = {**os.environ, "TERM": "dumb", "HOME": str(home)}

    for flags in [["-l", "-c"], ["-i", "-c"]]:
        try:
            r = subprocess.run(
                [shell] + flags + ["printf '%s' \"$PATH\""],
                capture_output=True, text=True, timeout=5, env=env,
            )
            if r.returncode == 0:
                # Skip any greeting lines; take the last one that looks like a PATH
                lines = [ln for ln in r.stdout.splitlines() if ":" in ln and "/" in ln]
                if lines:
                    os.environ["PATH"] = lines[-1]
                    if shutil.which("claude"):
                        return
        except Exception:
            pass

    # Manual fallback: common locations for npm/nvm/volta-installed binaries
    candidates = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(home / ".local" / "bin"),
        str(home / ".npm-global" / "bin"),
        str(home / ".volta" / "bin"),
    ]
    nvm_dir = home / ".nvm" / "versions" / "node"
    if nvm_dir.is_dir():
        try:
            for v in sorted(nvm_dir.iterdir(), reverse=True)[:5]:
                candidates.append(str(v / "bin"))
        except OSError:
            pass

    existing = os.environ.get("PATH", "")
    extra = ":".join(d for d in candidates if d not in existing and Path(d).is_dir())
    if extra:
        os.environ["PATH"] = extra + ":" + existing


def start_watcher(output: Path, poll_interval: int = 5) -> None:
    """Main loop. Writes PID file, polls for new transcripts, processes them.

    Args:
        output: Path to the output directory.
        poll_interval: Seconds between poll cycles.
    """
    global OUTPUT_DIR, PID_PATH, HEALTH_PATH
    OUTPUT_DIR = output
    PID_PATH = output / ".watcher.pid"
    HEALTH_PATH = output / ".watcher-health.json"

    _enrich_path_for_launchd()

    # Write PID file
    PID_PATH.write_text(str(os.getpid()))

    # Validate that Claude CLI is reachable
    model_ok = _validate_model()
    if not model_ok:
        print(
            "[WATCHER] Claude CLI is not reachable — transcripts will still be "
            "detected and renamed, but summaries will fail. "
            "Check that 'claude' is on PATH and authenticated.",
            file=sys.stderr,
        )

    # Install signal handlers
    signal.signal(signal.SIGTERM, lambda _sig, _frame: stop_watcher())
    signal.signal(signal.SIGINT, lambda _sig, _frame: stop_watcher())

    # Ensure directories exist
    output.mkdir(parents=True, exist_ok=True)
    (output / "inbox" / AUDIO_DIR_NAME).mkdir(parents=True, exist_ok=True)

    known_files: set = set()
    failure_counts: dict = {}
    started_at = datetime.now().isoformat(timespec="seconds")
    processed_today = 0

    update_health(processed_today, started_at=started_at)
    print(f"[WATCHER] Started. Monitoring {output}")
    print(f"[WATCHER] PID {os.getpid()}, poll interval {poll_interval}s")

    while True:
        try:
            new_files = poll_new_transcripts(known_files)
            for path in new_files:
                fname = path.name
                if failure_counts.get(fname, 0) >= _MAX_FAILURES:
                    continue

                if not is_debounced(path):
                    continue

                print(f"[WATCHER] Processing {fname}...")
                entry = process_transcript(path)
                if entry is not None:
                    known_files.add(entry.get("filename", fname))
                    processed_today += 1
                    update_health(processed_today, started_at=started_at)
                    status = entry.get("summary_status", "pending")
                    topic_count = entry.get("topic_count", 0)
                    if status == "complete":
                        print(f"[WATCHER] Done: {entry['title']} — summary=OK, topics={topic_count}")
                    else:
                        print(f"[WATCHER] Done: {entry['title']} — summary=FAILED, topics=SKIPPED")
                else:
                    failure_counts[fname] = failure_counts.get(fname, 0) + 1
                    if failure_counts[fname] >= _MAX_FAILURES:
                        print(f"[WATCHER] Skipping {fname} after {_MAX_FAILURES} failures")

            time.sleep(poll_interval)
        except Exception as exc:
            print(f"[WATCHER] Poll error: {exc}", file=sys.stderr)
            time.sleep(poll_interval)


def stop_watcher() -> None:
    """Signal handler for SIGTERM/SIGINT. Cleans up PID file and exits."""
    print("[WATCHER] Stopping...")
    try:
        if PID_PATH.exists():
            PID_PATH.unlink()
    except OSError:
        pass
    # Update health to stopped
    try:
        health = {}
        if HEALTH_PATH.exists():
            health = json.loads(HEALTH_PATH.read_text())
        health["status"] = "stopped"
        HEALTH_PATH.write_text(json.dumps(health, indent=2))
    except OSError:
        pass
    sys.exit(0)


def is_watcher_running() -> bool:
    """Check if a watcher process is alive by reading .watcher.pid and sending signal 0.

    Returns:
        True if PID file exists and the process is alive.
    """
    if not PID_PATH.exists():
        return False
    try:
        pid = int(PID_PATH.read_text().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, OSError, ProcessLookupError):
        return False


def get_watcher_health() -> dict:
    """Read .watcher-health.json.

    Returns:
        Dict with status, processed_today, last_check keys.
        Returns a default 'stopped' dict if file is missing.
    """
    if not HEALTH_PATH.exists():
        return {"status": "stopped", "processed_today": 0, "last_check": ""}
    try:
        return json.loads(HEALTH_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return {"status": "stopped", "processed_today": 0, "last_check": ""}


def poll_new_transcripts(known_files: set, output_dir: Path = None) -> list:
    """List .md files in output_dir not in known_files, not already enriched.

    Args:
        known_files: Set of filenames already processed this session.
        output_dir: Directory to scan. Defaults to OUTPUT_DIR.

    Returns:
        List of Paths to new, unprocessed transcript files.
    """
    scan_dir = output_dir or OUTPUT_DIR
    if not scan_dir.exists():
        return []

    results = []
    for entry in os.listdir(scan_dir):
        if not entry.endswith(".md"):
            continue
        if entry.endswith(".summary.md"):      # skip sidecars
            continue
        if entry in known_files:
            continue

        path = scan_dir / entry
        if not path.is_file():
            continue
        if is_already_processed(path):
            known_files.add(entry)
            continue

        results.append(path)

    return sorted(results, key=lambda p: p.stat().st_mtime)


def is_debounced(path: Path, wait_seconds: int = 5) -> bool:
    """Return True if file's mtime is at least wait_seconds old (not still being written).

    Args:
        path: Path to the file.
        wait_seconds: Minimum age in seconds.

    Returns:
        True if the file is old enough to process.
    """
    try:
        mtime = path.stat().st_mtime
        return (time.time() - mtime) >= wait_seconds
    except OSError:
        return False


def is_already_processed(path: Path) -> bool:
    """Return True if the file already has a 'processed_by:' line in its YAML front matter.

    Args:
        path: Path to the transcript file.

    Returns:
        True if the file has been processed by the background watcher.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False

    if not text.startswith("---"):
        return False

    end = text.find("\n---", 3)
    if end == -1:
        return False

    header = text[3:end]
    return "processed_by:" in header


def process_transcript(path: Path) -> Optional[dict]:
    """Full processing pipeline for one transcript.

    Steps: title inference → YAML enrich → summary generation.

    Args:
        path: Path to the transcript .md file.

    Returns:
        Dict with filename, title, date, summary_status, processed_at on success.
        None on failure.
    """
    if not path.exists():
        return None

    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    date_match = re.search(r"(\d{4}-\d{2}-\d{2})", path.name)
    file_date = date_match.group(1) if date_match else date.today().isoformat()
    now_str = datetime.now().isoformat(timespec="seconds")

    if not is_recorder_generated(path.name):
        title = deslugify(path.stem)
        title_source = "filename"
        metadata = {
            "title": title,
            "title_source": title_source,
            "date": file_date,
            "processed_by": "background",
            "processed_at": now_str,
        }
        new_path = enrich_yaml_header(path, metadata, skip_rename=True)
        _link_audio_by_prefix(path, new_path)
    else:
        title = infer_title_via_claude(text)
        title_source = "inferred"
        ts = _extract_recording_timestamp(text, file_date, filename=path.name)
        recording_time = ts.strftime("%H%M%S")
        metadata = {
            "title": title,
            "title_source": title_source,
            "date": file_date,
            "processed_by": "background",
            "processed_at": now_str,
        }
        new_path = enrich_yaml_header(path, metadata, recording_time=recording_time)
        _rename_and_link_audio(path, new_path)

    time.sleep(_CLI_DELAY_SECONDS)
    summary, topics = generate_summary(new_path)
    summary_status = "complete" if summary else "pending"

    if summary:
        _update_yaml_field(new_path, "summary", summary)

    write_sidecar(new_path, title, file_date, summary or "", topics)
    append_monthly_yaml(OUTPUT_DIR, title, file_date, new_path.name, summary or "", topics)

    topic_count = len(topics) if summary else 0
    return {
        "filename": new_path.name,
        "title": title,
        "date": file_date,
        "summary_status": summary_status,
        "topic_count": topic_count,
        "processed_at": now_str,
    }


def _extract_time_from_filename(filename: str) -> Optional[tuple]:
    """Extract (hour, minute, second) from a recorder-generated filename.

    Expects the pattern YYYY-MM-DD-HHMMSS-recording.md (matched by _RECORDER_PATTERN).

    Args:
        filename: The filename (not a full path), e.g. '2026-04-08-143022-recording.md'.

    Returns:
        (hour, minute, second) tuple if the filename matches and the time is valid,
        None otherwise.
    """
    if not filename:
        return None
    m = _FILENAME_TIME_RE.match(filename)
    if not m:
        return None
    try:
        h, minute = int(m.group(1)), int(m.group(2))
        s = int(m.group(3)) if m.group(3) else 0
    except (ValueError, AttributeError):
        return None
    if not (0 <= h <= 23 and 0 <= minute <= 59 and 0 <= s <= 59):
        return None
    return (h, minute, s)


def _extract_recording_timestamp(text: str, file_date: str, filename: str = "") -> datetime:
    """Extract the recording start time from filename, then transcript content.

    Fallback chain:
      1. Filename HHMMSS (second-precision, recorder-generated filenames)
      2. Content: '# Recording — YYYY-MM-DD HH:MM'
      3. Content: 'Time: HH:MM'
      4. Midnight on file_date

    Args:
        text: Full transcript text.
        file_date: ISO date string from filename (YYYY-MM-DD).
        filename: The filename (not a full path). Defaults to "".

    Returns:
        datetime with the recording start time, or midnight on file_date.
    """
    # Step 1: Try filename-based extraction (second-precision)
    if filename:
        parts = _extract_time_from_filename(filename)
        if parts is not None:
            h, m, s = parts
            try:
                return datetime.fromisoformat(f"{file_date}T{h:02d}:{m:02d}:{s:02d}")
            except ValueError:
                pass

    # Step 2: Content-based extraction (minute-precision)
    time_match = re.search(
        r"(?:"
        r"#\s*Recording\s*[—\-]\s*\d{4}-\d{2}-\d{2}\s+(\d{1,2}:\d{2}(?::\d{2})?)"
        r"|"
        r"^Time:\s*(\d{1,2}:\d{2}(?::\d{2})?)"
        r")",
        text,
        re.MULTILINE,
    )
    if time_match:
        time_str = time_match.group(1) or time_match.group(2)
        try:
            return datetime.fromisoformat(f"{file_date}T{time_str}")
        except ValueError:
            pass

    # Step 3: Midnight fallback
    try:
        return datetime.fromisoformat(file_date)
    except ValueError:
        return datetime.now()


def infer_title_via_claude(transcript_text: str) -> str:
    """Fallback: use Claude CLI to infer a meeting title from transcript content.

    Args:
        transcript_text: Full transcript text.

    Returns:
        Inferred title string, or 'Untitled Meeting' on failure.
    """
    opening = transcript_text[:500]
    prompt = (
        "Infer a concise meeting title (max 40 chars) from this transcript opening. "
        "Return ONLY the title, no quotes, no explanation."
    )

    try:
        result = subprocess.run(
            ["claude", "--model", _EXTRACTION_MODEL, "--output-format", "text", "-p", prompt],
            input=opening,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode != 0:
            return _infer_title_local(transcript_text)

        title = result.stdout.strip()
        if not title or len(title) > 60:
            return _infer_title_local(transcript_text)

        return title
    except (subprocess.TimeoutExpired, OSError, FileNotFoundError):
        return _infer_title_local(transcript_text)


def _infer_title_local(transcript_text: str) -> str:
    """Simple local title inference from transcript content without Claude CLI.

    Args:
        transcript_text: Full transcript text.

    Returns:
        Inferred title or 'Untitled Meeting'.
    """
    opening = transcript_text[:200].strip()
    patterns = [
        r"(?:this is|we're|welcome to|starting)\s+(?:the\s+)?([A-Z][^.!?]{5,40}(?:meeting|sync|review|standup|check.in|1:1|one.on.one))",
        r"(?:today's|this week's)\s+([A-Z][^.!?]{5,40})",
        r"##\s*Meeting:\s*(.+)",
    ]
    for pattern in patterns:
        m = re.search(pattern, opening, re.IGNORECASE)
        if m:
            return m.group(1).strip().title()

    return "Untitled Meeting"


def generate_summary(transcript_path: Path) -> tuple:
    """Invoke Claude CLI to generate summary and topics from transcript.

    Args:
        transcript_path: Path to the transcript file.

    Returns:
        Tuple of (summary_text, list_of_topic_strings).
        Either can be None/empty on failure.
    """
    prompt = (
        "Summarize this meeting. Return ONLY valid JSON:\n"
        '{"summary": "3-5 sentence summary. Active voice, numbers first, no filler.",\n'
        ' "topics": ["One sentence describing what was discussed or decided", ...]}\n'
        "Rules:\n"
        "- Active voice, direct. No passive constructions.\n"
        "- Numbers first: \"3 decisions\" not \"several decisions.\"\n"
        "- Extract 3-7 topics — the most important things discussed or decided in this meeting.\n"
        "- One sentence each. No owner names, no categories, no priority levels.\n"
        "- Focus on what matters: decisions made, problems raised, commitments given."
    )

    try:
        transcript_text = transcript_path.read_text(encoding="utf-8", errors="replace")
        input_len = len(transcript_text)
        print(f"[WATCHER] summary: input={input_len} chars, model={_EXTRACTION_MODEL}")

        result = None
        attempts = 1 + len(_RETRY_DELAYS)  # 1 initial + 2 retries
        for attempt in range(attempts):
            result = subprocess.run(
                ["claude", "--model", _EXTRACTION_MODEL, "--output-format", "text", "-p", prompt],
                input=transcript_text,
                capture_output=True,
                text=True,
                timeout=60,
            )

            print(f"[WATCHER] summary: attempt={attempt + 1}, exit_code={result.returncode}, "
                  f"stdout={len(result.stdout)} chars, stderr={len(result.stderr)} chars")

            if result.returncode == 0:
                break

            # Only retry on rate limit
            if "rate" in result.stderr.lower() and attempt < len(_RETRY_DELAYS):
                delay = _RETRY_DELAYS[attempt]
                print(f"[WATCHER] summary: RATE LIMITED — retry {attempt + 1}/{len(_RETRY_DELAYS)} in {delay}s")
                time.sleep(delay)
                continue

            # Non-rate-limit failure: don't retry
            stderr_safe = result.stderr[:200].replace('\n', ' ')
            print(f"[WATCHER] summary: CLI FAILED — exit={result.returncode}, hint={stderr_safe}")
            return None, []

        # If we exhausted retries on rate limits
        if result.returncode != 0:
            print(f"[WATCHER] summary: RATE LIMITED after {len(_RETRY_DELAYS)} retries — giving up")
            return None, []

        # Parse response
        output = result.stdout.strip()
        data = _extract_json(output)
        if data is None:
            raw_preview = output[:200].replace('\n', '\\n')
            print(f"[WATCHER] summary: JSON PARSE FAILED — raw_preview={raw_preview}")
            return None, []

        summary = data.get("summary")
        topics = data.get("topics", [])
        if not isinstance(topics, list):
            print(f"[WATCHER] summary: topics field is {type(topics).__name__}, expected list — resetting to []")
            topics = []

        summary_len = len(summary) if summary else 0
        preview = (summary[:80] + "...") if summary and len(summary) > 80 else (summary or "")
        print(f"[WATCHER] summary: OK — summary={summary_len} chars, topics={len(topics)} items, "
              f'preview="{preview}"')
        return summary, topics

    except subprocess.TimeoutExpired:
        print(f"[WATCHER] summary: TIMEOUT after 60s — input was {input_len} chars")
        return None, []
    except FileNotFoundError:
        print("[WATCHER] summary: claude CLI NOT FOUND — is it installed?")
        return None, []
    except OSError as e:
        print(f"[WATCHER] summary: OS ERROR — {type(e).__name__}")
        return None, []


def write_sidecar(
    transcript_path: Path,
    title: str,
    date: str,
    summary: str,
    topics: list,
) -> Path:
    """Write a summary sidecar file for a transcript.

    Creates a .summary.md file with YAML front matter and optional summary/topics sections.

    Args:
        transcript_path: Path to the transcript file.
        title: Meeting title.
        date: ISO date string (YYYY-MM-DD).
        summary: Summary text (can be empty).
        topics: List of topic strings.

    Returns:
        Path to the written sidecar file.
    """
    sidecar_path = transcript_path.parent / (transcript_path.stem + ".summary.md")

    lines = [
        "---",
        f"title: {title}",
        f"date: {date}",
        f"transcript: {transcript_path.name}",
        "---",
        "",
    ]

    if summary:
        lines.append(summary)
        lines.append("")

    if topics:
        lines.append("## Topics")
        lines.append("")
        for topic in topics:
            lines.append(f"- {topic}")
        lines.append("")

    sidecar_path.write_text("\n".join(lines), encoding="utf-8")
    return sidecar_path


def _yaml_scalar(value: str) -> str:
    """Escape a string for safe YAML output.

    Args:
        value: The string to escape.

    Returns:
        Properly quoted/escaped YAML scalar.
    """
    if not value:
        return '""'
    needs_quotes = any(c in value for c in ':{}[],"\'#&*!|>%@`\n\\') or value[0] in ' \t'
    if needs_quotes:
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def _build_yaml_entry(
    title: str,
    date: str,
    filename: str,
    summary: str,
    topics: list,
) -> str:
    """Build a single YAML entry for append_monthly_yaml.

    Args:
        title: Meeting title.
        date: ISO date string (YYYY-MM-DD).
        filename: Transcript filename.
        summary: Summary text.
        topics: List of topic strings.

    Returns:
        YAML entry as a string.
    """
    lines = [
        f"- title: {_yaml_scalar(title)}",
        f"  date: {date}",
        f"  file: {filename}",
        f"  summary: {_yaml_scalar(summary)}",
    ]
    if topics:
        lines.append("  topics:")
        for topic in topics:
            lines.append(f"    - {_yaml_scalar(topic)}")
    lines.append("")
    return "\n".join(lines) + "\n"


def _remove_yaml_entry_by_filename(content: str, filename: str) -> str:
    """Remove a YAML entry from content by matching its file field.

    Args:
        content: The YAML content.
        filename: The filename to match and remove.

    Returns:
        Content with the matching entry removed.
    """
    lines = content.splitlines(keepends=True)
    entry_start = None
    file_line_found = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("- title:"):
            if file_line_found:
                return "".join(lines[:entry_start]) + "".join(lines[i:])
            entry_start = i
            file_line_found = False
        if entry_start is not None and f"file: {filename}" in line:
            file_line_found = True

    if file_line_found and entry_start is not None:
        return "".join(lines[:entry_start])

    return content


def append_monthly_yaml(
    output_dir: Path,
    title: str,
    date: str,
    filename: str,
    summary: str,
    topics: list,
) -> None:
    """Append or update a meeting entry in a monthly YAML index file.

    Creates or updates a file named YYYY-MM.yaml with meeting metadata.
    If an entry with the same filename already exists, it is replaced.

    Args:
        output_dir: Directory where the YAML file is written.
        title: Meeting title.
        date: ISO date string (YYYY-MM-DD).
        filename: Transcript filename.
        summary: Summary text.
        topics: List of topic strings.
    """
    try:
        month = date[:7]  # "YYYY-MM"
    except (TypeError, IndexError):
        print(f"[WATCHER] append_monthly_yaml: invalid date {date!r} — skipping")
        return

    yaml_path = output_dir / f"{month}.yaml"
    new_entry = _build_yaml_entry(title, date, filename, summary, topics)

    if not yaml_path.exists():
        yaml_path.write_text(new_entry, encoding="utf-8")
        return

    existing = yaml_path.read_text(encoding="utf-8")
    cleaned = _remove_yaml_entry_by_filename(existing, filename)
    yaml_path.write_text(cleaned + new_entry, encoding="utf-8")


def slugify(title: str) -> str:
    """Convert title to filesystem-safe slug: lowercase, hyphens, max 60 chars.

    Args:
        title: The meeting title to slugify.

    Returns:
        Filesystem-safe slug string.
    """
    slug = title.lower()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_]+", "-", slug)
    slug = slug.strip("-")

    # Truncate at word boundary
    if len(slug) > 60:
        truncated = slug[:60]
        last_hyphen = truncated.rfind("-")
        if last_hyphen > 20:
            slug = truncated[:last_hyphen]
        else:
            slug = truncated

    return slug


def enrich_yaml_header(path: Path, metadata: dict, recording_time: str = "", skip_rename: bool = False) -> Path:
    """Add/update YAML front matter in transcript file. Returns new path if file was renamed.

    The output filename is ``{date}-{HHMMSS}-{slug}.md`` when recording_time is
    provided, or ``{date}-{slug}.md`` as a fallback. A collision guard appends
    ``-2``, ``-3``, … when the target file already exists and is a different
    file, preventing silent data loss for same-title same-day recordings.

    Args:
        path: Path to the transcript file.
        metadata: Dict of metadata fields to write.
        recording_time: ``HHMMSS`` string (e.g. ``"142700"``) for time-qualified
            filenames.  Empty string falls back to date-only.
        skip_rename: If True, write enriched content back to original path without renaming.

    Returns:
        The (possibly new) path to the file after enrichment/rename.
    """
    text = path.read_text(encoding="utf-8", errors="replace")

    # Build YAML front matter
    yaml_lines = ["---"]
    for key, value in metadata.items():
        if isinstance(value, str) and ("\n" in value or ":" in value or '"' in value):
            escaped = value.replace('"', '\\"')
            yaml_lines.append(f'{key}: "{escaped}"')
        elif isinstance(value, str):
            yaml_lines.append(f'{key}: "{value}"')
        elif isinstance(value, int):
            yaml_lines.append(f"{key}: {value}")
        else:
            yaml_lines.append(f"{key}: {value}")
    yaml_lines.append("---")
    yaml_header = "\n".join(yaml_lines) + "\n"

    # Strip existing front matter if present
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            text = text[end + 4:].lstrip("\n")

    new_content = yaml_header + text

    if skip_rename:
        # Write enriched content back to original path atomically
        tmp_path = path.parent / (path.name + ".tmp")
        tmp_path.write_text(new_content, encoding="utf-8")
        tmp_path.rename(path)
        return path

    # Determine new filename: {date}-{HHMMSS}-{slug}.md (time preferred) or {date}-{slug}.md
    title = metadata.get("title", "")
    file_date = metadata.get("date", "")
    if title and file_date:
        slug = slugify(title)
        if recording_time:
            base_name = f"{file_date}-{recording_time}-{slug}"
        else:
            base_name = f"{file_date}-{slug}"
        new_name = f"{base_name}.md"
    else:
        base_name = path.stem
        new_name = path.name

    # Collision guard: if target exists and is a different file, append counter.
    collision_fired = False
    new_path = path.parent / new_name
    if new_path.exists() and new_path.resolve() != path.resolve():
        counter = 2
        while new_path.exists() and new_path.resolve() != path.resolve():
            new_name = f"{base_name}-{counter}.md"
            new_path = path.parent / new_name
            counter += 1
        collision_fired = True
        print(f"[WATCHER] collision guard: renamed to {new_name}")

    # If collision guard fired, add collision_note to YAML
    if collision_fired:
        note = f"Duplicate filename detected — renamed to avoid overwriting {base_name}.md"
        escaped_note = note.replace('"', '\\"')
        # Insert collision_note line before the closing ---
        yaml_header = yaml_header.replace(
            "\n---\n",
            f'\ncollision_note: "{escaped_note}"\n---\n',
            1,
        )
        new_content = yaml_header + text

    # Write atomically via temp file
    tmp_path = path.parent / (new_name + ".tmp")
    tmp_path.write_text(new_content, encoding="utf-8")
    tmp_path.rename(new_path)

    # Remove old file if it was renamed
    if path != new_path and path.exists():
        try:
            path.unlink()
        except OSError:
            pass

    return new_path


def _update_yaml_field(path: Path, field: str, value: str) -> None:
    """Update a single field in an existing YAML front matter block.

    Args:
        path: Path to the file with YAML front matter.
        field: The YAML field name to update or add.
        value: The value to set.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.startswith("---"):
        return

    end = text.find("\n---", 3)
    if end == -1:
        return

    header = text[3:end]
    body = text[end + 4:]

    # Check if field already exists
    escaped = value.replace('"', '\\"')
    field_line = f'{field}: "{escaped}"'
    pattern = re.compile(rf"^{re.escape(field)}:.*$", re.MULTILINE)

    if pattern.search(header):
        header = pattern.sub(field_line, header)
    else:
        header = header.rstrip("\n") + "\n" + field_line

    new_text = "---" + header + "\n---" + body
    path.write_text(new_text, encoding="utf-8")


def _rename_and_link_audio(original_path: Path, new_path: Path) -> None:
    """Rename the audio sidecar alongside a recorder-generated transcript rename.

    Looks for ``{original_path.stem}.m4a`` in ``inbox/audio/``, renames it to
    ``{new_path.stem}.m4a``, and writes the ``audio:`` YAML field into *new_path*.
    Non-blocking — failures are logged but never raised.

    Args:
        original_path: The transcript path before enrichment/rename.
        new_path: The transcript path after enrichment/rename.
    """
    audio_dir = OUTPUT_DIR / "inbox" / AUDIO_DIR_NAME
    original_audio_name = original_path.stem + ".m4a"
    original_audio = audio_dir / original_audio_name

    if not original_audio.is_file():
        return

    new_audio_name = new_path.stem + ".m4a"
    new_audio = audio_dir / new_audio_name
    try:
        original_audio.rename(new_audio)
        audio_rel = f"inbox/{AUDIO_DIR_NAME}/{new_audio_name}"
        _update_yaml_field(new_path, "audio", audio_rel)
        print(f"[WATCHER] Audio linked: {new_audio_name}")
    except OSError as e:
        print(f"[WATCHER] Audio rename failed (non-blocking): {e}")


def _link_audio_by_prefix(original_path: Path, new_path: Path) -> None:
    """Link an audio sidecar to a user-named transcript by timestamp prefix.

    User-named files keep their original name; the recorder still created the
    audio file with the ``YYYY-MM-DD-HHMMSS`` timestamp prefix. Scan
    ``inbox/audio/`` for any audio file whose stem starts with the timestamp
    extracted from *original_path* and, if found, write an ``audio:`` YAML
    field into *new_path*.

    Args:
        original_path: The original (pre-enrichment) transcript path.
        new_path: The enriched transcript path to update with the audio field.
    """
    audio_dir = OUTPUT_DIR / "inbox" / AUDIO_DIR_NAME
    if not audio_dir.is_dir():
        return

    date_time_match = re.search(r"(\d{4}-\d{2}-\d{2}-\d{6})", original_path.name)
    if not date_time_match:
        return

    prefix = date_time_match.group(1)
    for af in audio_dir.iterdir():
        if af.stem.startswith(prefix) and af.suffix in _AUDIO_EXTENSIONS:
            audio_rel = f"inbox/{AUDIO_DIR_NAME}/{af.name}"
            _update_yaml_field(new_path, "audio", audio_rel)
            print(f"[WATCHER] Audio linked (user-named): {af.name}")
            break


def update_health(processed_today: int, started_at: str = "") -> None:
    """Write .watcher-health.json with current status, count, and timestamp.

    Args:
        processed_today: Number of transcripts processed today.
        started_at: ISO timestamp when the watcher started.
    """
    health = {
        "status": "running",
        "processed_today": processed_today,
        "last_check": datetime.now().isoformat(timespec="seconds"),
    }
    if started_at:
        health["started_at"] = started_at
    HEALTH_PATH.write_text(json.dumps(health, indent=2), encoding="utf-8")


def _extract_json(text: str) -> Optional[dict]:
    """Extract a JSON object from text that may contain code fences, nested braces, or prose."""
    stripped = text.strip()

    # Stage 1: Direct parse
    try:
        result = json.loads(stripped)
        if isinstance(result, dict):
            return result
    except json.JSONDecodeError:
        pass

    # Stage 2: Code-fence stripping
    fence_match = re.search(r"```(?:json)?\s*\n(.*?)\n\s*```", stripped, re.DOTALL)
    if fence_match:
        try:
            result = json.loads(fence_match.group(1).strip())
            if isinstance(result, dict):
                return result
        except json.JSONDecodeError:
            pass

    # Stage 3: Balanced-brace extraction (outermost {...})
    start = stripped.find("{")
    if start != -1:
        depth = 0
        for i in range(start, len(stripped)):
            if stripped[i] == "{":
                depth += 1
            elif stripped[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        result = json.loads(stripped[start:i + 1])
                        if isinstance(result, dict):
                            return result
                    except json.JSONDecodeError:
                        pass
                    break

    return None


def _parse_yaml_simple(header_text: str) -> dict:
    """Simple line-based YAML parser for our controlled front matter format.

    Handles: key: value, key: "quoted value", lists with - items.
    Does NOT handle nested maps, flow sequences, or complex YAML.

    Args:
        header_text: The text between --- delimiters (without the delimiters).

    Returns:
        Dict of parsed key-value pairs.
    """
    result: dict = {}
    current_key: Optional[str] = None
    current_list: Optional[list] = None

    for line in header_text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        # List item
        if stripped.startswith("- ") and current_key is not None and current_list is not None:
            current_list.append(stripped[2:].strip())
            result[current_key] = current_list
            continue

        # Key: value
        colon_idx = stripped.find(":")
        if colon_idx == -1:
            continue

        key = stripped[:colon_idx].strip()
        value = stripped[colon_idx + 1:].strip()

        if not value:
            # Start of a list
            current_key = key
            current_list = []
            result[key] = current_list
            continue

        current_key = None
        current_list = None

        # Strip quotes
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]

        # Try to parse as int
        try:
            result[key] = int(value)
        except ValueError:
            result[key] = value

    return result


# ── launchd agent management ──────────────────────────────────────────────────


def _resolve_launchd_path() -> str:
    """Build a PATH string for launchd that includes the claude binary's directory.

    Falls back to the current process PATH if claude is not found.
    """
    claude_bin = shutil.which("claude")
    base_path = os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    if claude_bin is None:
        return base_path
    claude_dir = str(Path(claude_bin).resolve().parent)
    # Prepend claude's directory if not already present
    dirs = base_path.split(os.pathsep)
    if claude_dir not in dirs:
        return f"{claude_dir}{os.pathsep}{base_path}"
    return base_path


def generate_launchd_plist(output: Path, poll_interval: int = 5) -> Path:
    """Generate a launchd user agent plist for the transcript watcher.

    Args:
        output: Path to the output directory.
        poll_interval: Seconds between poll cycles.

    Returns:
        Path to the written plist file in ~/Library/LaunchAgents/.
    """
    resolved_path = _resolve_launchd_path()
    python_path = sys.executable
    watcher_script = Path(__file__).resolve()

    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{_PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{python_path}</string>
        <string>{watcher_script}</string>
        <string>--output</string>
        <string>{output}</string>
        <string>--poll-interval</string>
        <string>{poll_interval}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{resolved_path}</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{output / ".watcher-stdout.log"}</string>
    <key>StandardErrorPath</key>
    <string>{output / ".watcher-stderr.log"}</string>
    <key>WorkingDirectory</key>
    <string>{output}</string>
</dict>
</plist>"""

    agents_dir = Path.home() / "Library" / "LaunchAgents"
    agents_dir.mkdir(parents=True, exist_ok=True)
    plist_path = agents_dir / f"{_PLIST_LABEL}.plist"
    plist_path.write_text(plist_content)
    return plist_path


def install_launchd_agent(output: Path, poll_interval: int = 5) -> bool:
    """Generate plist, unload any existing agent, and load the new one.

    Args:
        output: Path to the output directory.
        poll_interval: Seconds between poll cycles.

    Returns:
        True if launchctl load succeeded, False otherwise.
    """
    plist_path = generate_launchd_plist(output, poll_interval)

    # Unload existing agent (ignore errors if not loaded)
    subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)],
        capture_output=True,
    )

    # Load new agent
    result = subprocess.run(
        ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def uninstall_launchd_agent() -> bool:
    """Unload and remove the launchd agent plist.

    Returns:
        True if successfully unloaded, False otherwise.
    """
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{_PLIST_LABEL}.plist"
    if not plist_path.exists():
        return True

    result = subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)],
        capture_output=True,
    )
    try:
        plist_path.unlink()
    except OSError:
        pass
    return result.returncode == 0


def is_launchd_agent_loaded() -> bool:
    """Check if the launchd agent is currently loaded.

    Returns:
        True if the agent is loaded and running.
    """
    result = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{_PLIST_LABEL}"],
        capture_output=True,
    )
    return result.returncode == 0


# ── CLI ───────────────────────────────────────────────────────────────────────


def main() -> None:
    """CLI entry point for the watcher daemon."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Magpie Transcript Background Watcher",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_DIR,
        help="Path to output directory (default: auto-detected)",
    )
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=5,
        help="Seconds between poll cycles (default: 5)",
    )
    args = parser.parse_args()

    start_watcher(args.output, args.poll_interval)


if __name__ == "__main__":
    main()
