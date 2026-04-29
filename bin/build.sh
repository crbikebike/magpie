#!/usr/bin/env bash
# build.sh — Build Magpie.app
#
# Compiles Sources/ into a native macOS menubar app and installs
# it to ~/Applications/. No Xcode project required.
#
# Run once after cloning:
#   bash bin/build.sh
#
# Re-run after any Swift source change.
# No re-granting of permissions needed after rebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Magpie"
APP_DIR="$SCRIPT_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
BINARY="$MACOS_DIR/$APP_NAME"
SOURCES_DIR="$REPO_ROOT/Sources"
DEST_DIR="$HOME/Applications"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; exit 1; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           Build: Magpie              ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Check prerequisites ──────────────────────────────────────────────────────

if ! command -v swiftc &>/dev/null; then
    warn "swiftc not found — skipping build (install Xcode Command Line Tools: xcode-select --install)"
    exit 0
fi

if [ ! -d "$SOURCES_DIR" ]; then
    err "Sources directory not found: $SOURCES_DIR"
fi

SWIFT_SRC_FILES=("$SOURCES_DIR"/*.swift)
if [ ${#SWIFT_SRC_FILES[@]} -eq 0 ] || [ ! -f "${SWIFT_SRC_FILES[0]}" ]; then
    err "No Swift source files found in $SOURCES_DIR"
fi

SWIFT_VERSION=$(swiftc --version 2>&1 | head -1)
echo "→ $SWIFT_VERSION"
echo "→ Sources: $(echo "${SWIFT_SRC_FILES[@]}" | tr ' ' '\n' | sed 's|.*/||' | tr '\n' ' ')"
echo ""

# ── Create app bundle structure ──────────────────────────────────────────────

mkdir -p "$MACOS_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Magpie</string>
    <key>CFBundleDisplayName</key>
    <string>Magpie</string>
    <key>CFBundleIdentifier</key>
    <string>com.crbikebike.magpie</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>Magpie</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Magpie needs microphone access to record meeting audio.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Magpie captures system audio so your recordings include both sides of calls.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Magpie captures system audio for meeting transcription.</string>
</dict>
</plist>
PLIST

ok "App bundle structure created"

# ── Compile ──────────────────────────────────────────────────────────────────

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.4"

echo "→ Compiling ${#SWIFT_SRC_FILES[@]} files for $TARGET..."
swiftc "${SWIFT_SRC_FILES[@]}" \
    -parse-as-library \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework ScreenCaptureKit \
    -framework SwiftUI \
    -framework Accelerate \
    -target "$TARGET" \
    -O \
    -o "$BINARY"

ok "Compiled: $BINARY"

# ── Bundle Resources ─────────────────────────────────────────────────────────

RESOURCES_DEST="$APP_DIR/Contents/Resources"
mkdir -p "$RESOURCES_DEST"
cp "$REPO_ROOT/Resources/raven.svg" "$RESOURCES_DEST/"
cp "$REPO_ROOT/bin/watcher.py" "$RESOURCES_DEST/"
ok "Resources bundled: raven.svg, watcher.py"

# ── Signing ──────────────────────────────────────────────────────────────────
# Apple Development signing preserves TCC permissions across rebuilds.
# Falls back to ad-hoc if no certificate is available.

ENTITLEMENTS="$REPO_ROOT/Entitlements.plist"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGN_IDENTITY="Apple Development"
    ok "Found Apple Development certificate"
else
    SIGN_IDENTITY="-"
    warn "No Apple Development certificate — using ad-hoc signing (TCC will reset on each rebuild)"
fi

codesign --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --force --deep "$APP_DIR"
ok "Signed: $APP_DIR ($SIGN_IDENTITY)"

# ── Install to ~/Applications/ ───────────────────────────────────────────────

mkdir -p "$DEST_DIR"
DEST_APP="$DEST_DIR/${APP_NAME}.app"
rm -rf "$DEST_APP"
cp -r "$APP_DIR" "$DEST_APP"
codesign --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --force --deep "$DEST_APP"

ok "Installed: $DEST_APP"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo ""
echo "Launch Magpie:"
echo "  open ~/Applications/${APP_NAME}.app"
echo ""
echo "Install watcher dependencies:"
echo "  brew install yap"
echo "  # Claude Code must be installed and authenticated"
echo ""
