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

## Pairing with a knowledge base

Magpie outputs plain markdown. It works well as the capture layer for a larger system. A few setups worth considering instead of Notion:

- **[AI-Native Obsidian Vault](https://curiouslychase.com/posts/ai-native-obsidian-vault-setup-guide/)** — point your output folder at an Obsidian vault and use this setup guide to structure it as a living knowledge base. Claude Code handles synthesis, tagging, and cross-linking across your notes.

- **[LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)** — Karpathy's pattern for a persistent, LLM-maintained wiki. Feed meeting transcripts in; the LLM synthesizes them into interlinked pages that compound over time rather than piling up as raw files.

- **[Synthadoc](https://github.com/axoviq-ai/synthadoc)** — open-source wiki engine that transforms documents into a searchable, cross-linked knowledge graph at ingest time. Drop your `.md` transcripts in and get automatic linking and contradiction detection.

## Requirements

- macOS 14.4+
- [yap](https://github.com/ggerganov/whisper.cpp) (`brew install yap`)
- [Claude Code](https://claude.ai/code) installed and authenticated
