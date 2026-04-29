# Magpie + LLM Wiki Setup

Open a Claude Code session in the directory where you want your wiki. Then say:

> Read the instructions at https://github.com/crbikebike/magpie/blob/main/SETUP.md and follow them.

Claude Code will handle everything below. The only thing you do yourself is right-click → Open the installer at the end.

---

## Instructions for Claude Code

You are setting up a Magpie meeting recorder alongside an LLM Wiki knowledge base. Complete all steps in order. Tell the user what you're doing as you go.

### Step 1: Confirm macOS

```bash
sw_vers -productVersion
```

If this is not macOS 14.4 or later, stop and tell the user.

### Step 2: Install Homebrew (if missing)

```bash
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
brew --version
```

### Step 3: Install yap (if missing)

yap is the local speech-to-text engine Magpie uses.

```bash
if ! command -v yap &>/dev/null; then
    brew install yap
fi
yap --version
```

### Step 4: Create the wiki directory structure

Create the following in the current directory:

```
raw/
raw/Transcripts/     ← point Magpie's output folder here
wiki/
CLAUDE.md
```

```bash
mkdir -p raw/Transcripts wiki
```

### Step 5: Create wiki/index.md

```markdown
# Wiki Index

*Maintained by Claude. Updated on every ingest.*

| Page | Type | Summary |
|------|------|---------|
```

Write that content to `wiki/index.md`.

### Step 6: Create wiki/log.md

```markdown
# Log

*Append-only. Format: `## [YYYY-MM-DD] action | description`*
```

Write that content to `wiki/log.md`.

### Step 7: Write CLAUDE.md

Write the following to `CLAUDE.md` in the current directory:

```markdown
# Wiki Schema

Personal knowledge base built on the LLM Wiki pattern.
Meeting transcripts are captured by Magpie and land in raw/Transcripts/.

## Directory layout

    raw/                         — source documents, never modified
    raw/Transcripts/             — Magpie meeting recordings
      YYYY-MM-DD-HHMMSS-title.md          full transcript + YAML frontmatter
      YYYY-MM-DD-HHMMSS-title.summary.md  summary + topic list
      YYYY-MM.yaml                         monthly manifest
    wiki/                        — synthesized knowledge base (you maintain this)
      index.md                   catalog of every wiki page
      log.md                     append-only activity log
      *.md                       topic, entity, and concept pages

## Ingesting new transcripts

When new files appear in raw/Transcripts/ (or when asked to ingest):
1. Read each new .summary.md
2. Check the monthly .yaml manifest for surrounding context
3. Extract: decisions made, people mentioned, projects discussed, open questions
4. Create or update wiki pages for each entity and recurring topic
5. Update wiki/index.md — add new pages, refresh summaries of updated ones
6. Append to wiki/log.md: `## [YYYY-MM-DD] ingest | <meeting title>`

## Transcript format

Frontmatter fields in .md files: date, duration, audio_mode, vault
summary.md structure: YAML frontmatter with summary and topics array

Monthly .yaml manifest:
```yaml
- date: "2026-04-28"
  time: "14:30"
  title: "team sync"
  summary: "..."
  topics:
    - "..."
```

Use the manifest for quick scanning before reading full transcripts.

## Wiki page conventions

- One page per person, project, and recurring topic
- YAML frontmatter: type (person/project/topic), updated, source_count
- End entity pages with a ## Meetings section listing appearances
- Cross-link with [[Page Name]] syntax
- Active voice, no filler. Numbers first.

## Querying

1. Read wiki/index.md to find relevant pages
2. Read those pages
3. Synthesize an answer with citations
4. If the answer is worth keeping, write it as a new wiki page
```

### Step 8: Download the Magpie installer

```bash
pkg_url=$(curl -s https://api.github.com/repos/crbikebike/magpie/releases/latest \
  | python3 -c "import sys,json; a=json.load(sys.stdin)['assets']; print(next(x['browser_download_url'] for x in a if x['name'].endswith('.pkg')))")
curl -L "$pkg_url" -o ~/Downloads/Magpie-Installer.pkg
echo "Downloaded: ~/Downloads/Magpie-Installer.pkg"
```

### Step 9: Open Finder to the installer

```bash
open -R ~/Downloads/Magpie-Installer.pkg
```

### Step 10: Tell the user what to do next

Tell the user:

1. **Right-click** `Magpie-Installer.pkg` in the Finder window that just opened → choose **Open** → follow the prompts
2. After installing, open **Magpie** from Applications
3. When asked for an output folder, navigate to **[current directory]/raw/Transcripts** and select it
4. Grant **Microphone** access when prompted
5. Optionally grant **Screen & System Audio Recording** for capturing both sides of calls

That's it. Magpie will write transcripts to `raw/Transcripts/` and the wiki is ready to ingest them.
