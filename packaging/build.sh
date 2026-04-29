#!/usr/bin/env bash
# packaging/build.sh — Build Magpie.app for distribution.
#
# Calls the project's existing bin/build.sh to compile and bundle the app,
# then copies the result into packaging/build/ and re-signs it with the
# flags needed for a distributable pkg (hardened runtime, no timestamp server).
#
# Usage:
#   bash packaging/build.sh
#
# Output:
#   packaging/build/Magpie.app

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="Magpie"
BUNDLE_ID="com.crbikebike.magpie"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"

# ── Clean ─────────────────────────────────────────────────────────────────────
echo "→ Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Build ─────────────────────────────────────────────────────────────────────
echo "→ Building ${APP_NAME} via bin/build.sh..."
bash "$REPO_ROOT/bin/build.sh"

# bin/build.sh compiles to bin/Magpie.app before copying to ~/Applications.
# We use that intermediate bundle so packaging is independent of ~/Applications.
SRC_BUNDLE="$REPO_ROOT/bin/${APP_NAME}.app"
if [ ! -d "$SRC_BUNDLE" ]; then
    echo "❌ Expected build output not found: $SRC_BUNDLE"
    echo "   Check that bin/build.sh completed successfully."
    exit 1
fi

cp -r "$SRC_BUNDLE" "$APP_BUNDLE"

# ── Sign ──────────────────────────────────────────────────────────────────────
# Ad-hoc sign (identity "-") with hardened runtime enabled.
# --timestamp=none avoids a network call to Apple's timestamp server,
# which is only meaningful for notarized builds anyway.
echo "→ Signing ${APP_NAME}.app (ad-hoc, hardened runtime)..."
codesign \
    --sign - \
    --deep \
    --force \
    --options runtime \
    --timestamp=none \
    "$APP_BUNDLE"

# ── Verify ────────────────────────────────────────────────────────────────────
echo "→ Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"

echo ""
echo "✅ Build complete: $APP_BUNDLE"
echo "   Next: bash packaging/package.sh"
