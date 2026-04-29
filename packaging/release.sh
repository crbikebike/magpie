#!/usr/bin/env bash
# packaging/release.sh — Build, package, and publish a Magpie GitHub Release.
#
# Usage:
#   VERSION=1.2.0 bash packaging/release.sh
#
# Requires:
#   - gh CLI installed and authenticated (gh auth login)
#   - packaging/setup-signing-cert.sh must have run (or CERT_NAME cert in keychain)

set -euo pipefail

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    echo "❌ VERSION is required."
    echo "   Usage: VERSION=1.2.0 bash packaging/release.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINAL_PKG="$SCRIPT_DIR/dist/Magpie-${VERSION}-Installer.pkg"
STABLE_PKG="$SCRIPT_DIR/dist/Magpie-Installer.pkg"
TAG="v${VERSION}"

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI not found. Install it: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "❌ gh CLI not authenticated. Run: gh auth login"
    exit 1
fi

if gh release view "$TAG" &>/dev/null 2>&1; then
    echo "❌ Release $TAG already exists on GitHub."
    echo "   Delete it first: gh release delete $TAG --yes"
    exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────
echo "→ Building Magpie.app..."
bash "$SCRIPT_DIR/build.sh"

# ── Package ───────────────────────────────────────────────────────────────────
echo "→ Packaging..."
VERSION="$VERSION" bash "$SCRIPT_DIR/package.sh"

# ── Release ───────────────────────────────────────────────────────────────────
# Upload a stable-named copy so SETUP.md can use a version-independent download URL.
cp "$FINAL_PKG" "$STABLE_PKG"

echo "→ Creating GitHub Release $TAG..."
gh release create "$TAG" \
    "$FINAL_PKG" \
    "$STABLE_PKG" \
    --title "Magpie $VERSION" \
    --notes "$(cat <<NOTES
## Install with Claude Code (recommended)

Open Claude Code in the directory where you want your wiki, then say:

> Read the instructions at https://github.com/crbikebike/magpie/blob/main/SETUP.md and follow them.

Claude Code will install Homebrew, yap, set up an LLM Wiki, download the installer, and walk you through the rest.

---

## Manual install

1. Download **Magpie-${VERSION}-Installer.pkg** below
2. Right-click → **Open** (required first time — installer is self-signed)
3. Follow the prompts
4. Install yap: \`brew install yap\`
5. Open Magpie, choose your output folder, grant Microphone access

**Requires macOS 14.4+, [Claude Code](https://claude.ai/code) installed and authenticated.**
NOTES
)"

echo ""
echo "✅ Released: $(gh release view "$TAG" --json url -q .url)"
