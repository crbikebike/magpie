# tests/python/test_watcher_mcp.py
#
# Issue #20: the watcher's title/summary/validation subprocesses inherit the
# user's full MCP config. A connected MCP tool whose name exceeds the API's
# 128-char limit makes every `claude` call 400, so titles silently become
# "Untitled Meeting" and summaries are skipped. These calls need only Haiku
# text inference — no tools — so they must pass `--strict-mcp-config` (with no
# `--mcp-config`, that loads zero MCP servers).

import pytest


class _FakeCompleted:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _capturing_run(captured):
    """Replacement for subprocess.run that records the command and returns a
    benign success so the function under test runs to completion."""
    def fake_run(cmd, *args, **kwargs):
        captured["cmd"] = cmd
        return _FakeCompleted(returncode=0, stdout='{"summary": "s", "topics": []}', stderr="")
    return fake_run


def test_validate_model_uses_strict_mcp_config(monkeypatch):
    import watcher
    captured = {}
    monkeypatch.setattr(watcher.subprocess, "run", _capturing_run(captured))
    watcher._validate_model()
    assert "--strict-mcp-config" in captured["cmd"]


def test_infer_title_uses_strict_mcp_config(monkeypatch):
    import watcher
    captured = {}
    monkeypatch.setattr(watcher.subprocess, "run", _capturing_run(captured))
    watcher.infer_title_via_claude("Alice: welcome to the Q1 planning sync, let's begin.")
    assert "--strict-mcp-config" in captured["cmd"]


def test_generate_summary_uses_strict_mcp_config(monkeypatch, tmp_path):
    import watcher
    captured = {}
    monkeypatch.setattr(watcher.subprocess, "run", _capturing_run(captured))
    monkeypatch.setattr(watcher, "_SUMMARY_PROMPT", "summarize this", raising=False)
    transcript = tmp_path / "transcript.md"
    transcript.write_text("Some meeting transcript text.", encoding="utf-8")
    watcher.generate_summary(transcript)
    assert "--strict-mcp-config" in captured["cmd"]
