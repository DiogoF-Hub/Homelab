#!/bin/bash

# This script downloads pinned minisign binaries (Linux + Windows) from
# GitHub releases and stores them in a versioned directory.
# Old versions are never removed, allowing you to keep multiple versions
# side by side.
#
# Parity with setup-age.sh: same layout, same flow, same
# "update MINISIGN_VERSION in lib.sh" ending.
#
# Usage:
#   ./setup-minisign.sh              # Downloads the latest release from GitHub
#   ./setup-minisign.sh 0.12         # Downloads a specific version

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === CONFIGURATION ===
MINISIGN_TOOLS_DIR="/srv/tools/minisign"
GITHUB_API_URL="https://api.github.com/repos/jedisct1/minisign/releases/latest"
GITHUB_RELEASE_URL="https://github.com/jedisct1/minisign/releases/download"

# === RESOLVE VERSION ===
if [ -n "${1:-}" ]; then
    VERSION="$1"
    # Normalize: minisign tags are plain "0.12" (no leading "v"), strip it if present
    VERSION="${VERSION#v}"
    echo "[->] Using specified version: $VERSION"
else
    echo "[->] No version specified, fetching latest from GitHub..."
    VERSION=$(curl -sf "$GITHUB_API_URL" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
    # Strip leading "v" if the tag happens to have one (defensive; jedisct1's
    # tags are plain numbers today, but costs nothing).
    VERSION="${VERSION#v}"
    if [ -z "$VERSION" ]; then
        echo "[ERROR] Failed to fetch latest version from GitHub API."
        exit 1
    fi
    echo "[OK] Latest version: $VERSION"
fi

# === CHECK IF ALREADY DOWNLOADED ===
VERSION_DIR="${MINISIGN_TOOLS_DIR}/${VERSION}"
if [ -d "$VERSION_DIR" ] && [ -x "${VERSION_DIR}/minisign" ] && [ -f "${VERSION_DIR}/minisign.exe" ]; then
    echo "[OK] minisign $VERSION is already downloaded at $VERSION_DIR"
    echo ""
    echo "Currently installed versions:"
    ls -1d "${MINISIGN_TOOLS_DIR}"/* 2>/dev/null | xargs -I{} basename {} || true
    exit 0
fi

# === DOWNLOAD ===
# Upstream artifact names (verified against the extracted archives on hand):
#   Linux:   minisign-<ver>-linux.tar.gz         → minisign-linux/x86_64/minisign
#   Windows: minisign-<ver>-win64.zip            → minisign-win64/minisign.exe
LINUX_TARBALL="minisign-${VERSION}-linux.tar.gz"
WINDOWS_ZIP="minisign-${VERSION}-win64.zip"
LINUX_URL="${GITHUB_RELEASE_URL}/${VERSION}/${LINUX_TARBALL}"
WINDOWS_URL="${GITHUB_RELEASE_URL}/${VERSION}/${WINDOWS_ZIP}"
TMP_DIR=$(mktemp -d)

echo "[->] Downloading $LINUX_TARBALL..."
if ! curl -sfL -o "${TMP_DIR}/${LINUX_TARBALL}" "$LINUX_URL"; then
    echo "[ERROR] Failed to download $LINUX_URL"
    echo "        Check that version $VERSION exists at https://github.com/jedisct1/minisign/releases"
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "[OK] Downloaded Linux tarball"

echo "[->] Downloading $WINDOWS_ZIP..."
if ! curl -sfL -o "${TMP_DIR}/${WINDOWS_ZIP}" "$WINDOWS_URL"; then
    echo "[ERROR] Failed to download $WINDOWS_URL"
    echo "        Check that version $VERSION exists at https://github.com/jedisct1/minisign/releases"
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "[OK] Downloaded Windows zip"

# === EXTRACT ===
# Using find to locate the binaries inside the extracted archives.
# Upstream has shifted internal directory names in the past (e.g. 0.12
# changed the win64 zip layout, breaking the prior hard-coded path).
# find -type f -name minisign(.exe) -path '*linux*'/'*win*' is enough
# to disambiguate between Linux and Windows builds.
echo "[->] Extracting binaries..."
mkdir -p "$VERSION_DIR"

# Linux
mkdir -p "${TMP_DIR}/linux"
tar -xzf "${TMP_DIR}/${LINUX_TARBALL}" -C "${TMP_DIR}/linux"
LIN_BIN=$(find "${TMP_DIR}/linux" -type f -name minisign | head -1 || true)
[[ -z "$LIN_BIN" ]] && { echo "[ERROR] minisign binary not found in $LINUX_TARBALL"; rm -rf "$TMP_DIR"; exit 1; }
cp "$LIN_BIN" "${VERSION_DIR}/minisign"
chmod +x "${VERSION_DIR}/minisign"

# Windows: unzip if available, otherwise Python as fallback
mkdir -p "${TMP_DIR}/win"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${TMP_DIR}/${WINDOWS_ZIP}" -d "${TMP_DIR}/win"
else
    python3 -c "import zipfile; zipfile.ZipFile('${TMP_DIR}/${WINDOWS_ZIP}').extractall('${TMP_DIR}/win')"
fi
WIN_BIN=$(find "${TMP_DIR}/win" -type f -name minisign.exe | head -1 || true)
[[ -z "$WIN_BIN" ]] && { echo "[ERROR] minisign.exe not found in $WINDOWS_ZIP"; rm -rf "$TMP_DIR"; exit 1; }
cp "$WIN_BIN" "${VERSION_DIR}/minisign.exe"

# === COMPUTE CHECKSUMS ===
echo "[->] Computing checksums..."
sha256sum "${VERSION_DIR}/minisign"     | awk '{print $1}' > "${VERSION_DIR}/minisign.sha256"
sha256sum "${VERSION_DIR}/minisign.exe" | awk '{print $1}' > "${VERSION_DIR}/minisign.exe.sha256"

# === CLEANUP ===
rm -rf "$TMP_DIR"

# === VERIFY ===
INSTALLED_VERSION=$("${VERSION_DIR}/minisign" -v 2>&1 || true)
echo ""
echo "[OK] minisign $VERSION installed successfully at $VERSION_DIR"
echo "     Binary reports: $INSTALLED_VERSION"
echo ""
echo "     Linux:"
echo "       minisign SHA-256:       $(cat "${VERSION_DIR}/minisign.sha256")"
echo "     Windows:"
echo "       minisign.exe SHA-256:   $(cat "${VERSION_DIR}/minisign.exe.sha256")"

# === LIST ALL VERSIONS ===
echo ""
echo "Installed versions:"
ls -1d "${MINISIGN_TOOLS_DIR}"/* 2>/dev/null | xargs -I{} basename {} || true

echo ""
echo "[!] To use this version for backups, update MINISIGN_VERSION in lib.sh:"
echo "    MINISIGN_VERSION=\"$VERSION\""
