#!/usr/bin/env bash
# packaging/setup-signing-cert.sh — Create a self-signed certificate for pkg signing.
#
# Run this once before packaging. Creates a certificate named "Magpie Installer Signing"
# in your login keychain. package.sh looks for this certificate by that name.
#
# Usage:
#   bash packaging/setup-signing-cert.sh
#
# To remove the certificate later:
#   security delete-certificate -c "Magpie Installer Signing" ~/Library/Keychains/login.keychain-db

set -euo pipefail

CERT_NAME="Magpie Installer Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "→ Checking for existing certificate..."
if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" &>/dev/null 2>&1; then
    echo "✅ Certificate already exists: \"${CERT_NAME}\""
    echo "   Nothing to do. Delete it first if you want to regenerate:"
    echo "   security delete-certificate -c \"${CERT_NAME}\" ~/Library/Keychains/login.keychain-db"
    exit 0
fi

KEY="$WORK_DIR/magpie-signing.key"
CERT="$WORK_DIR/magpie-signing.crt"
P12="$WORK_DIR/magpie-signing.p12"

# Temporary password for the p12 bundle (only used during import)
P12_PASS="magpie-temp-$$"

echo "→ Generating RSA key..."
openssl genrsa -out "$KEY" 2048 2>/dev/null

echo "→ Generating self-signed certificate (valid 10 years)..."
openssl req -new -x509 \
    -key "$KEY" \
    -out "$CERT" \
    -days 3650 \
    -subj "/CN=${CERT_NAME}/O=Magpie/OU=Installer Signing" \
    2>/dev/null

echo "→ Bundling into PKCS#12..."
openssl pkcs12 -export \
    -in "$CERT" \
    -inkey "$KEY" \
    -out "$P12" \
    -passout "pass:${P12_PASS}" \
    2>/dev/null

echo "→ Importing into login keychain..."
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/productsign \
    -T /usr/bin/security \
    2>/dev/null

# Mark the certificate as trusted for code signing
CERT_SHA=$(security find-certificate -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/SHA-1/{print $NF}' | head -1)

if [ -n "$CERT_SHA" ]; then
    security add-trusted-cert \
        -d \
        -r trustRoot \
        -k "$KEYCHAIN" \
        "$CERT" 2>/dev/null || true
fi

echo ""
echo "✅ Certificate created: \"${CERT_NAME}\""
echo "   Run: bash packaging/package.sh"
echo ""
echo "   Note: macOS will prompt for your login keychain password during packaging."
