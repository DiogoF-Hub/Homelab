#!/bin/bash

# This script downloads pinned age binaries (Linux + Windows) from GitHub releases
# and stores them in a versioned directory.
# Old versions are never removed, allowing you to keep multiple versions side by side.
#
# Usage:
#   ./setup-age.sh              # Downloads the latest release from GitHub
#   ./setup-age.sh v1.3.1       # Downloads a specific version

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === CONFIGURATION ===
AGE_TOOLS_DIR="/srv/tools/age"
GITHUB_API_URL="https://api.github.com/repos/FiloSottile/age/releases/latest"
GITHUB_RELEASE_URL="https://github.com/FiloSottile/age/releases/download"

# === RESOLVE VERSION ===
if [ -n "${1:-}" ]; then
    VERSION="$1"
    # Normalize: ensure the version starts with "v"
    if [[ "$VERSION" != v* ]]; then
        VERSION="v${VERSION}"
    fi
    echo "[->] Using specified version: $VERSION"
else
    echo "[->] No version specified, fetching latest from GitHub..."
    VERSION=$(curl -sf "$GITHUB_API_URL" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
    if [ -z "$VERSION" ]; then
        echo "[ERROR] Failed to fetch latest version from GitHub API."
        exit 1
    fi
    echo "[OK] Latest version: $VERSION"
fi

# === CHECK IF ALREADY DOWNLOADED ===
VERSION_DIR="${AGE_TOOLS_DIR}/${VERSION}"
if [ -d "$VERSION_DIR" ] && [ -x "${VERSION_DIR}/age" ] && [ -f "${VERSION_DIR}/age.exe" ]; then
    echo "[OK] age $VERSION is already downloaded at $VERSION_DIR"
    echo ""
    echo "Currently installed versions:"
    ls -1d "${AGE_TOOLS_DIR}"/v* 2>/dev/null | xargs -I{} basename {} || true
    exit 0
fi

# === DOWNLOAD ===
LINUX_TARBALL="age-${VERSION}-linux-amd64.tar.gz"
WINDOWS_ZIP="age-${VERSION}-windows-amd64.zip"
LINUX_URL="${GITHUB_RELEASE_URL}/${VERSION}/${LINUX_TARBALL}"
WINDOWS_URL="${GITHUB_RELEASE_URL}/${VERSION}/${WINDOWS_ZIP}"
TMP_DIR=$(mktemp -d)

echo "[->] Downloading $LINUX_TARBALL..."
if ! curl -sfL -o "${TMP_DIR}/${LINUX_TARBALL}" "$LINUX_URL"; then
    echo "[ERROR] Failed to download $LINUX_URL"
    echo "        Check that version $VERSION exists at https://github.com/FiloSottile/age/releases"
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "[OK] Downloaded Linux binary"

echo "[->] Downloading $WINDOWS_ZIP..."
if ! curl -sfL -o "${TMP_DIR}/${WINDOWS_ZIP}" "$WINDOWS_URL"; then
    echo "[ERROR] Failed to download $WINDOWS_URL"
    echo "        Check that version $VERSION exists at https://github.com/FiloSottile/age/releases"
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "[OK] Downloaded Windows binary"

# === EXTRACT ===
echo "[->] Extracting binaries..."
mkdir -p "$VERSION_DIR"

# Linux tarball contains an "age/" directory with the binaries
tar -xzf "${TMP_DIR}/${LINUX_TARBALL}" -C "$TMP_DIR"
cp "${TMP_DIR}/age/age" "${VERSION_DIR}/age"
cp "${TMP_DIR}/age/age-keygen" "${VERSION_DIR}/age-keygen"
chmod +x "${VERSION_DIR}/age" "${VERSION_DIR}/age-keygen"

# Windows zip contains an "age/" directory with .exe binaries
# Using unzip if available, otherwise Python as fallback
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "${TMP_DIR}/${WINDOWS_ZIP}" -d "${TMP_DIR}/win"
else
    python3 -c "import zipfile; zipfile.ZipFile('${TMP_DIR}/${WINDOWS_ZIP}').extractall('${TMP_DIR}/win')"
fi
cp "${TMP_DIR}/win/age/age.exe" "${VERSION_DIR}/age.exe"
cp "${TMP_DIR}/win/age/age-keygen.exe" "${VERSION_DIR}/age-keygen.exe"

# === COMPUTE CHECKSUMS ===
echo "[->] Computing checksums..."
sha256sum "${VERSION_DIR}/age" | awk '{print $1}' > "${VERSION_DIR}/age.sha256"
sha256sum "${VERSION_DIR}/age-keygen" | awk '{print $1}' > "${VERSION_DIR}/age-keygen.sha256"
sha256sum "${VERSION_DIR}/age.exe" | awk '{print $1}' > "${VERSION_DIR}/age.exe.sha256"
sha256sum "${VERSION_DIR}/age-keygen.exe" | awk '{print $1}' > "${VERSION_DIR}/age-keygen.exe.sha256"

# === CLEANUP ===
rm -rf "$TMP_DIR"

# === VERIFY ===
INSTALLED_VERSION=$("${VERSION_DIR}/age" --version 2>&1 || true)
echo ""
echo "[OK] age $VERSION installed successfully at $VERSION_DIR"
echo "     Binary reports: $INSTALLED_VERSION"
echo ""
echo "     Linux:"
echo "       age SHA-256:            $(cat "${VERSION_DIR}/age.sha256")"
echo "       age-keygen SHA-256:     $(cat "${VERSION_DIR}/age-keygen.sha256")"
echo "     Windows:"
echo "       age.exe SHA-256:        $(cat "${VERSION_DIR}/age.exe.sha256")"
echo "       age-keygen.exe SHA-256: $(cat "${VERSION_DIR}/age-keygen.exe.sha256")"

# === LIST ALL VERSIONS ===
echo ""
echo "Installed versions:"
ls -1d "${AGE_TOOLS_DIR}"/v* 2>/dev/null | xargs -I{} basename {} || true

echo ""
echo "[!] To use this version for backups, update AGE_VERSION in main.sh:"
echo "    AGE_VERSION=\"$VERSION\""
