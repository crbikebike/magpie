# tests/python/test_watcher.py
import pytest
from pathlib import Path


# ── write_sidecar ─────────────────────────────────────────────────────────────

def test_write_sidecar_creates_file(tmp_path):
    from watcher import write_sidecar
    transcript = tmp_path / "2026-04-28-143022-team-sync.md"
    transcript.write_text("# Recording\nsome content")

    sidecar = write_sidecar(
        transcript_path=transcript,
        title="Team Sync",
        date="2026-04-28",
        summary="The team aligned on Q2 priorities.",
        topics=["Auth refactor due May 15", "EU work deferred to Q3"],
    )

    assert sidecar == tmp_path / "2026-04-28-143022-team-sync.summary.md"
    assert sidecar.exists()


def test_write_sidecar_content(tmp_path):
    from watcher import write_sidecar
    transcript = tmp_path / "2026-04-28-143022-team-sync.md"
    transcript.write_text("# Recording")

    sidecar = write_sidecar(
        transcript_path=transcript,
        title="Team Sync",
        date="2026-04-28",
        summary="The team aligned on Q2 priorities.",
        topics=["Auth refactor due May 15", "EU deferred to Q3"],
    )

    content = sidecar.read_text()
    assert "title: Team Sync" in content
    assert "date: 2026-04-28" in content
    assert "transcript: 2026-04-28-143022-team-sync.md" in content
    assert "The team aligned on Q2 priorities." in content
    assert "## Topics" in content
    assert "- Auth refactor due May 15" in content
    assert "- EU deferred to Q3" in content


def test_write_sidecar_no_topics_omits_section(tmp_path):
    from watcher import write_sidecar
    transcript = tmp_path / "2026-04-28-143022-meeting.md"
    transcript.write_text("# Recording")

    sidecar = write_sidecar(
        transcript_path=transcript,
        title="Meeting",
        date="2026-04-28",
        summary="Quick sync.",
        topics=[],
    )

    assert "## Topics" not in sidecar.read_text()


def test_write_sidecar_overwrites_existing(tmp_path):
    from watcher import write_sidecar
    transcript = tmp_path / "2026-04-28-143022-meeting.md"
    transcript.write_text("# Recording")

    write_sidecar(transcript, "Meeting", "2026-04-28", "First summary.", [])
    write_sidecar(transcript, "Meeting", "2026-04-28", "Second summary.", [])

    content = (tmp_path / "2026-04-28-143022-meeting.summary.md").read_text()
    assert "Second summary." in content
    assert "First summary." not in content


# ── append_monthly_yaml ───────────────────────────────────────────────────────

def test_append_monthly_yaml_creates_file(tmp_path):
    from watcher import append_monthly_yaml
    append_monthly_yaml(
        output_dir=tmp_path,
        title="Team Sync",
        date="2026-04-28",
        filename="2026-04-28-143022-team-sync.md",
        summary="Q2 priorities aligned.",
        topics=["Auth refactor due May 15"],
    )

    assert (tmp_path / "2026-04.yaml").exists()


def test_append_monthly_yaml_content(tmp_path):
    from watcher import append_monthly_yaml
    append_monthly_yaml(
        output_dir=tmp_path,
        title="Team Sync",
        date="2026-04-28",
        filename="2026-04-28-143022-team-sync.md",
        summary="Q2 priorities aligned.",
        topics=["Auth refactor due May 15", "EU deferred to Q3"],
    )

    content = (tmp_path / "2026-04.yaml").read_text()
    assert "Team Sync" in content
    assert "2026-04-28" in content
    assert "2026-04-28-143022-team-sync.md" in content
    assert "Q2 priorities aligned." in content
    assert "Auth refactor due May 15" in content
    assert "EU deferred to Q3" in content


def test_append_monthly_yaml_deduplicates_by_filename(tmp_path):
    from watcher import append_monthly_yaml
    for i in range(2):
        append_monthly_yaml(
            output_dir=tmp_path,
            title="Team Sync",
            date="2026-04-28",
            filename="2026-04-28-143022-team-sync.md",
            summary=f"Summary version {i}.",
            topics=[],
        )

    content = (tmp_path / "2026-04.yaml").read_text()
    assert content.count("2026-04-28-143022-team-sync.md") == 1
    assert "Summary version 1." in content
    assert "Summary version 0." not in content


def test_append_monthly_yaml_multiple_meetings(tmp_path):
    from watcher import append_monthly_yaml
    append_monthly_yaml(tmp_path, "Meeting A", "2026-04-28", "a.md", "Summary A.", [])
    append_monthly_yaml(tmp_path, "Meeting B", "2026-04-27", "b.md", "Summary B.", [])

    content = (tmp_path / "2026-04.yaml").read_text()
    assert "Meeting A" in content
    assert "Meeting B" in content


def test_append_monthly_yaml_separate_months(tmp_path):
    from watcher import append_monthly_yaml
    append_monthly_yaml(tmp_path, "April Meeting", "2026-04-28", "april.md", "Summary.", [])
    append_monthly_yaml(tmp_path, "May Meeting", "2026-05-01", "may.md", "Summary.", [])

    assert (tmp_path / "2026-04.yaml").exists()
    assert (tmp_path / "2026-05.yaml").exists()
    assert "April Meeting" not in (tmp_path / "2026-05.yaml").read_text()


# ── poll_new_transcripts filtering ───────────────────────────────────────────

def test_poll_skips_summary_files(tmp_path):
    from watcher import poll_new_transcripts
    (tmp_path / "2026-04-28-143022-meeting.md").write_text("# Recording")
    (tmp_path / "2026-04-28-143022-meeting.summary.md").write_text("# Summary")

    results = poll_new_transcripts(set(), output_dir=tmp_path)
    names = [p.name for p in results]

    assert "2026-04-28-143022-meeting.md" in names
    assert "2026-04-28-143022-meeting.summary.md" not in names


def test_poll_skips_yaml_files(tmp_path):
    from watcher import poll_new_transcripts
    (tmp_path / "2026-04-28-143022-meeting.md").write_text("# Recording")
    (tmp_path / "2026-04.yaml").write_text("- title: Meeting")

    results = poll_new_transcripts(set(), output_dir=tmp_path)
    names = [p.name for p in results]

    assert "2026-04.yaml" not in names


def test_poll_skips_already_processed(tmp_path):
    from watcher import poll_new_transcripts
    processed = tmp_path / "2026-04-28-143022-done.md"
    processed.write_text("---\nprocessed_by: \"background\"\n---\n# Recording")

    results = poll_new_transcripts(set(), output_dir=tmp_path)
    assert not any(p.name == "done.md" for p in results)


def test_poll_skips_known_files(tmp_path):
    from watcher import poll_new_transcripts
    f = tmp_path / "2026-04-28-143022-meeting.md"
    f.write_text("# Recording")

    results = poll_new_transcripts({"2026-04-28-143022-meeting.md"}, output_dir=tmp_path)
    assert len(results) == 0
