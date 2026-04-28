#!/usr/bin/env bash
#
# reboot.sh — always reboot the VM at the end of the nightly cycle.
#
# Policy decision: we always reboot, not just when Debian's
# /var/run/reboot-required is present. That flag only covers
# kernel/libc/etc. and misses reasons like "container service image got
# updated" — rebooting unconditionally is simpler and safer than trying
# to reason about "is a reboot really needed right now?".
#
# Writes into the MAIN log rather than a separate reboot log, so the
# "did we actually reboot?" signal is visible inline with the rest of
# the orchestrator's output.
#
# Runnable standalone:   sudo /root/vault/reboot.sh
# Called from main.sh:   /root/vault/reboot.sh
#
# Exit codes (see EXIT_CODE_DESC in lib.sh):
#   0  — rebooted (only visible in the log — /sbin/reboot replaces the
#        process before we return here)
#   40 — reboot blocked by safety check (containers still running or
#        apt/dpkg lock held)

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

# Write into the main log — no separate reboot log file.
PHASE_LOG="$MAIN_LOG"

require_root
ensure_log_dirs

log "reboot phase starting"

# --- safety checks --------------------------------------------------------

# Refuse to reboot if containers are still running. main.sh stops them via
# backup.sh earlier in the cycle; this is a belt-and-suspenders guard for
# standalone invocations and for the (rare) case where stop_containers
# didn't fully complete.
#
# Use `podman-compose ps` (cwd=COMPOSE_DIR) to enumerate, NOT bare
# `podman ps`. Reason: rootless podman's state lives under
# /run/user/<poduser-uid> via XDG_RUNTIME_DIR; `sudo -u poduser` does
# not inherit that env var, so `sudo -u poduser podman ps` returns
# empty even when containers are running and this safety check would
# silently pass. `podman-compose` bootstraps its own session context.
cd "$COMPOSE_DIR" || fail "cannot access compose directory: $COMPOSE_DIR" 40
running=$(sudo -u "$USER_POD" podman-compose ps 2>/dev/null | tail -n +2 | grep -c . || true)
if (( running > 0 )); then
    fail "refusing to reboot: $running containers still running (stop them first)" 40
fi

# Refuse to reboot if a dpkg/apt lock is held — mid-upgrade reboot bricks
# the package database.
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
   || fuser /var/lib/apt/lists/lock    >/dev/null 2>&1; then
    fail "refusing to reboot: apt/dpkg lock currently held" 40
fi

# --- do it -----------------------------------------------------------------

log "all safety checks passed — REBOOT COMMAND being issued in 5 seconds"

sync
sleep 5
exec /sbin/reboot -h now
