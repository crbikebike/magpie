#!/usr/bin/env bash
# packaging/package.sh — Create a distributable .pkg installer for Magpie.
#
# Requires:
#   1. packaging/build.sh must have run first (packaging/build/Magpie.app exists)
#   2. packaging/setup-signing-cert.sh must have run (cert in login keychain)
#
# Usage:
#   bash packaging/package.sh
#   VERSION=1.2.0 bash packaging/package.sh
#
# Output:
#   packaging/dist/Magpie-<VERSION>-Installer.pkg

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="Magpie"
BUNDLE_ID="com.crbikebike.magpie"
VERSION="${VERSION:-1.0.0}"
CERT_NAME="${CERT_NAME:-Magpie Installer Signing}"
INSTALL_LOCATION="/Applications"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"
WORK_DIR="$SCRIPT_DIR/.pkgwork"

APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
COMPONENT_PKG="$WORK_DIR/component.pkg"
UNSIGNED_PKG="$WORK_DIR/${APP_NAME}-unsigned.pkg"
FINAL_PKG="$DIST_DIR/${APP_NAME}-${VERSION}-Installer.pkg"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ App bundle not found: $APP_BUNDLE"
    echo "   Run: bash packaging/build.sh"
    exit 1
fi

# postinstall must be executable for pkgbuild to accept it
chmod +x "$SCRIPT_DIR/scripts/postinstall"

# ── Clean ─────────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

# ── Component package ─────────────────────────────────────────────────────────
# pkgbuild creates a "component" pkg — the raw payload (the .app) plus scripts.
# --root points at the directory whose contents get installed at INSTALL_LOCATION.
# --scripts points at the directory containing preinstall/postinstall hooks.
echo "→ Building component package..."
pkgbuild \
    --root "$BUILD_DIR" \
    --install-location "$INSTALL_LOCATION" \
    --identifier "${BUNDLE_ID}.pkg" \
    --version "$VERSION" \
    --scripts "$SCRIPT_DIR/scripts" \
    "$COMPONENT_PKG"

# ── Distribution XML ──────────────────────────────────────────────────────────
# productbuild reads this to configure the installer UI: title, screens, choices.
DIST_XML="$WORK_DIR/distribution.xml"
cat > "$DIST_XML" << XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${APP_NAME}</title>
    <welcome    file="welcome.html"    mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <!-- customize="never" hides the component list — there's only one thing to install -->
    <options customize="never" require-scripts="true"/>
    <!-- enable_localSystem allows installing to /Applications without a user home dir -->
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="${BUNDLE_ID}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${BUNDLE_ID}" visible="false">
        <pkg-ref id="${BUNDLE_ID}"/>
    </choice>
    <pkg-ref id="${BUNDLE_ID}" version="${VERSION}" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

# ── Distribution package ──────────────────────────────────────────────────────
# productbuild wraps the component pkg with the installer UI and resources.
# --package-path tells it where to find component.pkg (referenced in distribution.xml).
echo "→ Building distribution package..."
productbuild \
    --distribution "$DIST_XML" \
    --resources "$SCRIPT_DIR/resources" \
    --package-path "$WORK_DIR" \
    "$UNSIGNED_PKG"

# ── Sign ──────────────────────────────────────────────────────────────────────
# A signed pkg lets macOS verify the installer hasn't been tampered with.
# Users still see "unidentified developer" (no paid Apple Developer ID),
# but they won't get "pkg is damaged" errors. See README for user instructions.
echo "→ Signing package..."
if security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db &>/dev/null 2>&1; then
    productsign \
        --sign "$CERT_NAME" \
        "$UNSIGNED_PKG" \
        "$FINAL_PKG"
    echo "   Signed with: \"${CERT_NAME}\""
else
    echo "⚠️  Cert \"${CERT_NAME}\" not found — distributing unsigned."
    echo "   Run packaging/setup-signing-cert.sh to create it."
    cp "$UNSIGNED_PKG" "$FINAL_PKG"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

SIZE="$(du -sh "$FINAL_PKG" | cut -f1)"
echo ""
echo "✅ Package ready: $FINAL_PKG ($SIZE)"
echo "   Share this file with your friends."
echo ""
echo "   Remind them: right-click → Open the first time (see packaging/README.md)."
