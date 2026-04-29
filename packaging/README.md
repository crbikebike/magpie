# Magpie Packaging

Builds a distributable `.pkg` installer for Magpie. No Apple Developer account required.

## One-time setup

```bash
bash packaging/setup-signing-cert.sh
```

Creates a self-signed certificate named "Magpie Installer Signing" in your login keychain. This certificate signs the package so macOS won't report it as damaged, but users still need to right-click → Open on first run (no paid Developer ID).

## Build and package

```bash
# Step 1 — compile and sign Magpie.app
bash packaging/build.sh

# Step 2 — wrap it in a .pkg installer
VERSION=1.2.0 bash packaging/package.sh
```

Output: `packaging/dist/Magpie-1.2.0-Installer.pkg`

If `VERSION` is omitted, defaults to `1.0.0`.

## Distributing

Share `packaging/dist/Magpie-<VERSION>-Installer.pkg` directly.

**Tell recipients:** Right-click the `.pkg` → **Open** the first time. This one-time step bypasses Gatekeeper for unsigned/self-signed packages.

After that, Magpie launches normally from Applications.

## What each script does

| Script | Purpose |
|--------|---------|
| `setup-signing-cert.sh` | One-time: creates signing cert in login keychain |
| `build.sh` | Calls `bin/build.sh`, copies app, re-signs with hardened runtime |
| `package.sh` | `pkgbuild` → `productbuild` → `productsign` → final `.pkg` |
| `scripts/postinstall` | Strips quarantine xattr after install |
| `resources/welcome.html` | Installer welcome screen |
| `resources/conclusion.html` | Installer completion screen |

## Re-signing note

`build.sh` re-signs the app with `--options runtime` (hardened runtime) and `--timestamp=none`. This is required for `pkgbuild` to accept the payload without notarization. The original `bin/build.sh` sign step uses Apple Development certs when available; the packaging step normalizes this to ad-hoc regardless.

## Removing the signing certificate

```bash
security delete-certificate -c "Magpie Installer Signing" ~/Library/Keychains/login.keychain-db
```
