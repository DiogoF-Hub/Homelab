#!/usr/bin/env bash
#
# main.sh — orchestrator for the nightly Vaultwarden maintenance run.
#
# This is the ONLY script that cron should invoke. It:
#   1. Acquires a lock (prevents concurrent/overlapping cron runs).
#   2. Calls backup.sh. On failure → abort. No point updating a host
#      whose data could not be captured.
#   3. Calls docker-update.sh. On failure → log and continue.
#   4. Calls system-update.sh. On failure → log and continue (updates
#      can retry tomorrow; a pending reboot for yesterday's kernel is
#      still useful).
#   5. Pings the deadman's switch endpoint (if configured) on success.
#   6. Calls reboot.sh. reboot.sh decides internally whether to reboot.
#
# All phase scripts (backup.sh, docker-update.sh, system-update.sh,
# reboot.sh) and lib.sh live in the SAME directory as this file.
# On the VM they are deployed together into /root/ (or wherever root's
# maintenance scripts live). Failure modes and their numeric exit codes
# live in lib.sh (EXIT_CODE_DESC) and are narrated automatically via
# explain_exit_code().
#
# Exit codes of main.sh itself:
#   0  — everything OK (or gracefully degraded)
#   1  — lock already held by another run
#   2  — lib.sh missing or malformed
#   10-127 — propagated from a sub-script (see lib.sh)

set -euo pipefail

# Resolve the directory of this script so siblings are always found
# regardless of where cron invokes it from.
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SCRIPTS_DIR="${SELF_DIR}"

# shellcheck source=lib.sh
source "${SCRIPTS_DIR}/lib.sh" || { echo "FATAL: cannot source ${SCRIPTS_DIR}/lib.sh" >&2; exit 2; }

PHASE_LOG="$MAIN_LOG"

require_root
require_cmd flock
ensure_log_dirs

# ---- locking --------------------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%H:%M:%S')] [main.sh] $(explain_exit_code 1)" | tee -a "$PHASE_LOG" >&2
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT

{
    echo
    echo "================================================"
    echo "Maintenance run started at: $(date)"
    echo "Host: $(hostname)   PID: $$"
    echo "================================================"
} >> "$PHASE_LOG"

log "orchestrator starting"

# Helper: run a sub-script, log a narrated status line, return its rc.
# Usage: run_phase "backup" "${SCRIPTS_DIR}/backup.sh"
run_phase() {
    local label="$1" script="$2"
    log "phase: ${label} — running ${script##*/}"
    local rc=0
    "$script" || rc=$?
    if (( rc == 0 )); then
        log "phase: ${label} — OK"
    else
        log "phase: ${label} — FAILED $(explain_exit_code "$rc")"
    fi
    return "$rc"
}

# ---- phase 1: backup (mandatory) -----------------------------------------

if run_phase "backup" "${SCRIPTS_DIR}/backup.sh"; then
    BACKUP_OK=1
else
    RC=$?
    log "aborting maintenance run — backup is non-negotiable"
    echo "STATUS: BACKUP_FAILED $(explain_exit_code "$RC") at $(date)" >> "$PHASE_LOG"
    exit "$RC"
fi

# ---- phase 2: docker update (non-fatal on failure) -----------------------

DOCKER_UPDATE_OK=0
if run_phase "docker-update" "${SCRIPTS_DIR}/docker-update.sh"; then
    DOCKER_UPDATE_OK=1
fi

# ---- phase 3: system update (non-fatal on failure) -----------------------

SYSTEM_UPDATE_OK=0
if run_phase "system-update" "${SCRIPTS_DIR}/system-update.sh"; then
    SYSTEM_UPDATE_OK=1
fi

# ---- deadman ping (only after a successful backup) ----------------------
# The backup is the thing that actually matters — a failed update cycle
# does not invalidate the signal that the backup ran.

(( BACKUP_OK == 1 )) && deadman_ping

# ---- phase 4: reboot (always) --------------------------------------------

REBOOT_OK=0
# reboot.sh always reboots unless a safety gate (containers still running
# or apt/dpkg lock held) blocks it. On a successful reboot, /sbin/reboot
# replaces the process and we never return — so REBOOT_OK=1 only ever
# lands if the script exited 0 without actually rebooting (which should
# not happen in the current implementation, but we keep the branch so
# future reboot.sh changes don't silently break the summary block).
if run_phase "reboot" "${SCRIPTS_DIR}/reboot.sh"; then
    REBOOT_OK=1
fi

# ---- summary --------------------------------------------------------------

if (( BACKUP_OK == 1 && DOCKER_UPDATE_OK == 1 && SYSTEM_UPDATE_OK == 1 && REBOOT_OK == 1 )); then
    STATUS="OK"
elif (( BACKUP_OK == 1 && DOCKER_UPDATE_OK == 0 && SYSTEM_UPDATE_OK == 1 )); then
    STATUS="DOCKER_UPDATE_FAILED_BACKUP_OK"
elif (( BACKUP_OK == 1 && DOCKER_UPDATE_OK == 1 && SYSTEM_UPDATE_OK == 0 )); then
    STATUS="SYSTEM_UPDATE_FAILED_BACKUP_OK"
elif (( BACKUP_OK == 1 && DOCKER_UPDATE_OK == 0 && SYSTEM_UPDATE_OK == 0 )); then
    STATUS="UPDATES_FAILED_BACKUP_OK"
elif (( BACKUP_OK == 1 && REBOOT_OK == 0 )); then
    STATUS="REBOOT_BLOCKED_BACKUP_OK"
else
    STATUS="DEGRADED"
fi

{
    echo "================================================"
    echo "Maintenance run finished at: $(date)"
    echo "STATUS: $STATUS"
    echo "================================================"
} >> "$PHASE_LOG"

log "orchestrator done: $STATUS"

# Retention on the orchestrator log itself
find "$MAIN_LOG_DIR" -name "main-*.log" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true

exit 0
