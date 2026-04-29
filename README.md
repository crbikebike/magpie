# Magpie

A magpie for your meetings. Collects what matters, leaves the rest.

Records meetings, transcribes them with [yap](https://github.com/ggerganov/whisper.cpp), and auto-generates a summary + topic list using Claude.

## What you get

For each recording, two files land in your output folder:

- `2026-04-28-143022-team-sync.md` — full transcript with YAML frontmatter
- `2026-04-28-143022-team-sync.summary.md` — summary + topics, ready for Obsidian

Plus a monthly index: `2026-04.yaml` — a list of all meetings with titles, summaries, and topics. Designed for LLMs to read across.

## Install

Build from source — this avoids macOS Gatekeeper entirely since the binary is compiled on your machine.

**If you use Claude Code**, open a session anywhere and run:

```
/install-magpie
```

That command handles everything: clones the repo, installs dependencies, and builds the app.

**Or build manually:**

```bash
# Prerequisites
brew install yap
# Claude Code must be installed and authenticated (claude on your PATH)

git clone https://github.com/crbikebike/magpie.git ~/magpie
bash ~/magpie/bin/build.sh
```

Magpie.app will be in `~/Applications/`.

## First launch

1. Open Magpie from Applications
2. Grant **Microphone** permission when prompted
3. Optionally grant **Screen & System Audio Recording** (for capturing both sides of Zoom/Meet/Teams calls)
4. Choose your **Output Folder** — point this at your Obsidian vault or any folder you want
5. The watcher daemon starts automatically

## Hotkey

**Cmd+Shift+R** — start/stop recording from anywhere.

## Audio modes

- **Mic Only** — records your voice
- **System Only** — records everything playing through your Mac (calls, videos)
- **Mic + System** — both sides of the conversation (recommended for calls with headphones)

## Updating

**If you use Claude Code**, run from any session:

```
/update-magpie
```

**Or manually:**

```bash
cd ~/magpie && git pull && bash bin/build.sh
```

## Requirements

- macOS 14.4+
- [yap](https://github.com/ggerganov/whisper.cpp) (`brew install yap`)
- [Claude Code](https://claude.ai/code) installed and authenticated
