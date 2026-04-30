#!/usr/bin/env bash
#
# backup.sh: tar /srv/vw-data, encrypt with age, sign with minisign (if
# enabled), package into a self-contained bundle, apply retention.
#
# Runnable standalone:   sudo /root/vault/backup.sh
# Called from main.sh:   /root/vault/backup.sh
#
# Exit codes:
#   10: age prerequisites missing
#   11: tar failed
#   12: age encryption failed
#   13: minisign prerequisites missing or signing failed
#   14: bundle creation failed

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

PHASE_LOG="$BACKUP_LOG"

require_root
require_cmd tar
require_cmd sha256sum
require_cmd curl

ensure_log_dirs

{
    echo
    echo "================================================"
    echo "Vaultwarden backup started at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "backup starting"

# --- prereqs ---------------------------------------------------------------

verify_age_prereqs
if $SIGN_BACKUPS; then
    verify_minisign_prereqs
else
    warn "SIGN_BACKUPS=false, bundle will NOT be signed. Set it to true once minisign is configured."
fi

# --- stop containers (idempotent) -----------------------------------------

stop_containers

# --- paths for this run ----------------------------------------------------

ARCHIVE_NAME="vw-data-backup-${TODAY_DATE}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
ENCRYPTED_ARCHIVE="${ARCHIVE_PATH}.age"
SIGNATURE_FILE="${ENCRYPTED_ARCHIVE}.minisig"
MANIFEST="${BACKUP_DIR}/manifest-${TODAY_DATE}.txt"

BUNDLE_AGE_BINARY="${BACKUP_DIR}/age"
BUNDLE_AGE_BINARY_WIN="${BACKUP_DIR}/age.exe"
BUNDLE_MINISIGN_BINARY="${BACKUP_DIR}/minisign"
BUNDLE_MINISIGN_BINARY_WIN="${BACKUP_DIR}/minisign.exe"
BUNDLE_DECRYPT_TXT="${BACKUP_DIR}/DECRYPT.txt"
FINAL_BUNDLE="${BACKUP_DIR}/vaultwarden-backup-bundle-${TODAY_DATE}.tar.gz"

# --- tar + encrypt ---------------------------------------------------------

log "creating tar archive of $VW_DATA_DIR"
tar -czvf "$ARCHIVE_PATH" -C "$VW_DATA_DIR" . >> "$PHASE_LOG" 2>&1 \
    || fail "tar failed" 11
log "archive created at $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | awk '{print $1}'))"

log "encrypting with age (X25519, recipient=${AGE_RECIPIENT:0:20}...)"
"$AGE_BINARY" -r "$AGE_RECIPIENT" -o "$ENCRYPTED_ARCHIVE" "$ARCHIVE_PATH" \
    || fail "age encryption failed" 12
log "encrypted archive at $ENCRYPTED_ARCHIVE"

# --- sign with minisign ----------------------------------------------------

if $SIGN_BACKUPS; then
    log "signing encrypted archive with minisign"
    # -S = sign, -s = secret key, -m = message file, -x = output .minisig.
    # If MINISIGN_KEY_PASSPHRASE_FILE is set, read passphrase from it; else
    # assume the private key was generated without a passphrase (unattended).
    if [[ -n "$MINISIGN_KEY_PASSPHRASE_FILE" && -f "$MINISIGN_KEY_PASSPHRASE_FILE" ]]; then
        "$MINISIGN_BINARY" -S -s "$MINISIGN_KEY" \
            -m "$ENCRYPTED_ARCHIVE" \
            -x "$SIGNATURE_FILE" \
            < "$MINISIGN_KEY_PASSPHRASE_FILE" \
            >> "$PHASE_LOG" 2>&1 \
            || fail "minisign signing failed" 13
    else
        # -W = do not prompt for a password (unencrypted key)
        "$MINISIGN_BINARY" -S -W -s "$MINISIGN_KEY" \
            -m "$ENCRYPTED_ARCHIVE" \
            -x "$SIGNATURE_FILE" \
            >> "$PHASE_LOG" 2>&1 \
            || fail "minisign signing failed" 13
    fi
    log "signature written to $SIGNATURE_FILE"
fi

# --- manifest --------------------------------------------------------------

log "generating manifest"
ARCHIVE_SHA256=$(sha256sum "$ENCRYPTED_ARCHIVE" | awk '{print $1}')
AGE_BINARY_SHA256=$(sha256sum "$AGE_BINARY" | awk '{print $1}')
AGE_BINARY_WIN_SHA256=$(sha256sum "$AGE_BINARY_WIN" | awk '{print $1}')

{
    echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "age_version=$AGE_VERSION"
    echo "archive_sha256=$ARCHIVE_SHA256"
    echo "age_binary_sha256=$AGE_BINARY_SHA256"
    echo "age_binary_win_sha256=$AGE_BINARY_WIN_SHA256"
    echo "recipient_public_key=$AGE_RECIPIENT"
    if $SIGN_BACKUPS; then
        echo "minisign_version=$MINISIGN_VERSION"
        echo "signature_sha256=$(sha256sum "$SIGNATURE_FILE" | awk '{print $1}')"
        echo "minisign_binary_sha256=$(sha256sum "$MINISIGN_BINARY" | awk '{print $1}')"
        echo "minisign_binary_win_sha256=$(sha256sum "$MINISIGN_BINARY_WIN" | awk '{print $1}')"
        echo "minisign_pubkey=$(grep -v '^untrusted' "$MINISIGN_PUBKEY_FILE" | tr -d '\n')"
    else
        echo "signed=false"
    fi
} > "$MANIFEST"
log "manifest written to $MANIFEST"

# --- bundle contents -------------------------------------------------------

log "staging bundle contents"
cp "$AGE_BINARY"     "$BUNDLE_AGE_BINARY"
cp "$AGE_BINARY_WIN" "$BUNDLE_AGE_BINARY_WIN"

if $SIGN_BACKUPS; then
    cp "$MINISIGN_BINARY"      "$BUNDLE_MINISIGN_BINARY"
    cp "$MINISIGN_BINARY_WIN"  "$BUNDLE_MINISIGN_BINARY_WIN"
    # Note: minisign.pub is deliberately NOT bundled. Verifiers must use
    # their own trusted copy (a pubkey from the same bundle proves nothing).
    # The pubkey string is recorded in the manifest for key-rotation lookup.
fi

if [[ -f "$DECRYPT_TXT" ]]; then
    cp "$DECRYPT_TXT" "$BUNDLE_DECRYPT_TXT"
else
    warn "DECRYPT.txt not found at $DECRYPT_TXT, skipping"
fi

# --- final bundle ----------------------------------------------------------

log "packaging final bundle"
BUNDLE_FILES=("$(basename "$ENCRYPTED_ARCHIVE")" "$(basename "$MANIFEST")" "age" "age.exe")
$SIGN_BACKUPS && BUNDLE_FILES+=("$(basename "$SIGNATURE_FILE")" "minisign" "minisign.exe")
[[ -f "$BUNDLE_DECRYPT_TXT" ]] && BUNDLE_FILES+=("DECRYPT.txt")

tar -czvf "$FINAL_BUNDLE" -C "$BACKUP_DIR" "${BUNDLE_FILES[@]}" >> "$PHASE_LOG" 2>&1 \
    || fail "final bundle creation failed" 14

log "final bundle written to $FINAL_BUNDLE ($(du -h "$FINAL_BUNDLE" | awk '{print $1}'))"

# --- cleanup intermediates -------------------------------------------------

log "cleaning intermediate files"
rm -f "$ARCHIVE_PATH" "$ENCRYPTED_ARCHIVE" "$SIGNATURE_FILE" "$MANIFEST" \
      "$BUNDLE_AGE_BINARY" "$BUNDLE_AGE_BINARY_WIN" \
      "$BUNDLE_MINISIGN_BINARY" "$BUNDLE_MINISIGN_BINARY_WIN" \
      "$BUNDLE_DECRYPT_TXT"

# --- check for newer upstream releases (informational only) ---------------
#
# Query both GitHub APIs, then emit one tightly-grouped status block so the
# result is easy to scan at a glance, especially on a phone screen. Status
# markers in a fixed column ([OK] / [!!] / [??]) make any non-OK row jump
# out from the vertical strip.

LATEST_AGE=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/FiloSottile/age/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//' || true)

if [[ -z "$LATEST_AGE" ]]; then
    AGE_LINE="  [??] age could not query GitHub"
elif [[ "$LATEST_AGE" != "$AGE_VERSION" ]]; then
    AGE_LINE="  [!!] age $AGE_VERSION -> $LATEST_AGE AVAILABLE"
else
    AGE_LINE="  [OK] age $AGE_VERSION (latest)"
fi

MINISIGN_LINE=""
if $SIGN_BACKUPS; then
    LATEST_MINISIGN=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/jedisct1/minisign/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//' | sed 's/^v//' || true)

    if [[ -z "$LATEST_MINISIGN" ]]; then
        MINISIGN_LINE="  [??] minisign could not query GitHub"
    elif [[ "$LATEST_MINISIGN" != "$MINISIGN_VERSION" ]]; then
        MINISIGN_LINE="  [!!] minisign $MINISIGN_VERSION -> $LATEST_MINISIGN AVAILABLE"
    else
        MINISIGN_LINE="  [OK] minisign $MINISIGN_VERSION (latest)"
    fi
fi

# Emit as one block: one blank line above, no blanks between internal
# lines, shared timestamp on every line so it reads as a single unit.
RELEASE_CHECK_TS="[$(date '+%H:%M:%S')]"
{
    printf '\n'
    printf '%s ======== upstream release check =======\n' "$RELEASE_CHECK_TS"
    printf '%s %s\n' "$RELEASE_CHECK_TS" "$AGE_LINE"
    [[ -n "$MINISIGN_LINE" ]] && printf '%s %s\n' "$RELEASE_CHECK_TS" "$MINISIGN_LINE"
    printf '%s ==================================\n' "$RELEASE_CHECK_TS"
} | tee -a "$PHASE_LOG"

# --- retention -------------------------------------------------------------

log "applying retention (${RETENTION_DAYS} days)"
find "$BACKUP_DIR"     -maxdepth 1 -name "vaultwarden-backup-bundle-*.tar.gz" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true
find "$BACKUP_LOG_DIR" -name "vault-backup-*.log" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true

{
    echo "================================================"
    echo "Vaultwarden backup finished at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "backup complete"
exit 0
