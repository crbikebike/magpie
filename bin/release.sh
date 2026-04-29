#!/usr/bin/env bash
# release.sh — Build, zip, and publish a new Magpie release.
#
# Usage: bash bin/release.sh <version>
# Example: bash bin/release.sh 1.0.0
#
# Prerequisites:
#   - gh CLI authenticated
#   - homebrew-tap repo cloned at ~/homebrew-tap (or set HOMEBREW_TAP_DIR)

set -euo pipefail

VERSION="${1:?Usage: bash bin/release.sh <version>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Magpie"
ZIP_NAME="${APP_NAME}.zip"
TAP_DIR="${HOMEBREW_TAP_DIR:-"$HOME/homebrew-tap"}"

GREEN='\033[0;32m'; NC='\033[0m'
ok() { echo -e "${GREEN}✅ $1${NC}"; }

echo "→ Building ${APP_NAME} v${VERSION}..."
bash "$SCRIPT_DIR/build.sh"
ok "Build complete"

# Update version in Info.plist
DEST_APP="$HOME/Applications/${APP_NAME}.app"
PLIST="$DEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"

# Re-sign after plist edit
codesign --sign "-" --entitlements "$REPO_ROOT/Entitlements.plist" --force --deep "$DEST_APP"

# Zip the app
cd "$HOME/Applications"
zip -r "$REPO_ROOT/$ZIP_NAME" "${APP_NAME}.app"
ok "Zipped: $ZIP_NAME"

# Compute sha256
SHA=$(shasum -a 256 "$REPO_ROOT/$ZIP_NAME" | awk '{print $1}')
ok "SHA256: $SHA"

# Create GitHub release
gh release create "v${VERSION}" \
  "$REPO_ROOT/$ZIP_NAME" \
  --repo crbikebike/magpie \
  --title "Magpie v${VERSION}" \
  --notes "See README for install instructions."
ok "GitHub release v${VERSION} created"

# Update tap
CASK="$TAP_DIR/Casks/magpie.rb"
if [ -f "$CASK" ]; then
  sed -i '' "s/version \".*\"/version \"${VERSION}\"/" "$CASK"
  sed -i '' "s/sha256 .*/sha256 \"${SHA}\"/" "$CASK"
  cd "$TAP_DIR"
  git add Casks/magpie.rb
  git commit -m "chore: bump magpie to v${VERSION}"
  git push origin main
  ok "Tap updated: v${VERSION}, sha256=${SHA}"
else
  echo "⚠ Tap not found at $CASK — update manually"
  echo "  version \"${VERSION}\""
  echo "  sha256  \"${SHA}\""
fi

echo ""
echo "Coworkers install with:"
echo "  brew install --cask crbikebike/tap/magpie"
echo "Existing installs update with:"
echo "  brew upgrade --cask magpie"
