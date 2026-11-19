#!/usr/bin/env bash
#
# modsec-archive.sh: extend modsec_audit.log retention past BunkerWeb's 14-day logrotate window.
#
# Started 2026-09-16 as a temporary helper (temp_modsec-archive.sh, gitignored), kept
# and published 2026-11-19: the 60-day archive is what known-attacks.json's second pass
# was built from, and it's the only place older WAF history lives.
#
# BunkerWeb's own logrotate (inside the container) keeps 14 rotated copies of
# modsec_audit.log (see CLAUDE.md § Logrotate; the old host config is retired). Fine for day-to-day ops, too
# short for "check the WAF logs every few weeks" review, by the time you get
# to it the interesting days have already aged out. This copies each rotated
# .gz into a 60-day archive under /srv/logs/, then prunes anything older than
# that from the archive itself.
#
# Deliberately standalone, NOT wired into main.sh. This is pure archive+prune
# with no failure mode that should ever abort a backup or block a reboot, so
# it doesn't belong in that orchestrator's phase/safety-gate model. Runs on
# its own cron line instead (see bottom of this file for the entry).
#
# Why content-hash dedup instead of "just grab .1.gz daily": rotation isn't
# on a fixed clock (observed happening at all different times of day on this
# VM, not clustered near midnight), so a naive "copy .1.gz once a day" script
# could either double-copy the same rotation or miss one entirely depending
# on exactly when it runs relative to logrotate. Hashing the content and
# skipping if that hash is already archived makes re-running any number of
# times, at any time, a no-op for files already captured.
#
# Only touches the *.gz rotated files, never the live modsec_audit.log
# itself (still being appended to by BunkerWeb, copying it mid-write would
# risk grabbing a torn/partial JSON line).
#
# Needs root: /srv/bw-logs/* is owned by the rootless podman container's
# mapped UID (165636 here), not readable by poduser or a regular user.
#
# Runnable standalone: sudo /root/vault/root_scripts/modsec-archive.sh

set -euo pipefail

SRC_DIR="/srv/bw-logs"
ARCHIVE_DIR="/srv/logs/modsec-archive"
RETENTION_DAYS=60

if [[ "$(id -u)" -ne 0 ]]; then
  echo "modsec-archive.sh: must run as root (source logs aren't readable otherwise)" >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"

shopt -s nullglob
for f in "$SRC_DIR"/modsec_audit.log.*.gz; do
  hash=$(sha256sum "$f" | cut -c1-16)
  log_date=$(date -d "@$(stat -c %Y "$f")" +%F)
  dest="$ARCHIVE_DIR/modsec_audit-${log_date}-${hash}.log.gz"

  if [[ -e "$dest" ]]; then
    continue
  fi

  # -p preserves the source's mtime, so the prune step below prunes by the
  # log's actual date, not by whatever day we happened to copy it. That also
  # carries over the source's ownership (the container's mapped UID, e.g.
  # 165636), which cp -p preserves along with the timestamp; re-own to root
  # since we're root anyway and there's no reason the archive should depend
  # on that UID mapping staying the same across a future rootless-podman
  # reinstall.
  cp -p "$f" "$dest"
  chown root:root "$dest"
done
shopt -u nullglob

# Prune archive entries older than the retention window. Uses the preserved
# mtime from the cp -p above, so this is "60 days since the log was rotated",
# not "60 days since we archived it".
find "$ARCHIVE_DIR" -name 'modsec_audit-*.log.gz' -mtime "+${RETENTION_DAYS}" -delete

# Weekly rule-count snapshot (Sundays). One of these every week gives real
# history to diff against (which rules fire more or less over time); the manual
# habit never stuck (first file only showed up 2026-10-18). Never pruned, a
# file is under 1 KB.
#
# Reads the live log + the archive ONLY, not $SRC_DIR/*.gz too. The loop above
# just copied every rotated file into the archive, so reading both would count
# the last ~14 days twice.
#
# fromjson? instead of plain jq: the live log is still being appended to, and
# a torn last line would make jq bail and kill the whole snapshot.
SNAP_DIR="/srv/logs/modsec"
if [[ "$(date +%u)" == 7 ]] && command -v jq >/dev/null; then
  mkdir -p "$SNAP_DIR"
  snap="$SNAP_DIR/modsec-counts-$(date +%F).txt"
  shopt -s nullglob
  logs=("$SRC_DIR"/modsec_audit.log "$ARCHIVE_DIR"/modsec_audit-*.log.gz)
  shopt -u nullglob
  zcat -f "${logs[@]}" \
    | jq -rR 'fromjson? | .transaction.messages[]?.details.ruleId' \
    | sort | uniq -c | sort -rn > "$snap.tmp"
  mv "$snap.tmp" "$snap"
fi

# --- Cron entry (add via `sudo crontab -e`) ---
# Once a day is enough; dedup makes running more often harmless too.
#   15 3 * * * /root/vault/root_scripts/modsec-archive.sh > /dev/null 2>&1
