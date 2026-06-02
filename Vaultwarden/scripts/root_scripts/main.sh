#!/usr/bin/env bash
#
# main.sh: orchestrator for the nightly Vaultwarden maintenance run.
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
#   0:  everything OK (or gracefully degraded)
#   1:  lock already held by another run
#   2:  lib.sh missing or malformed
#   10-127: propagated from a sub-script (see lib.sh)

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

# Unique id for this run, exported so every phase script stamps its status
# lines with it; the finish trap then rolls those lines up into the single
# `run` summary event the nightly Discord report fires on.
export MAINT_RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"

# emit_run_summary RC, roll this run's per-phase status lines into one
# `run` event. overall = fail if any phase failed, else degraded if any
# degraded, else ok; carries the docker image lists + apt list so the
# Discord report has them in one message. Uses jq when present; without
# jq it still emits an overall-only summary, so a missing jq never blocks
# the run (jq is only needed for the rich rollup).
emit_run_summary() {
    local rc="$1"
    [[ -f "$STATUS_LOG" ]] || return 0
    local lines
    lines=$(grep -F "\"run_id\":\"${MAINT_RUN_ID}\"" "$STATUS_LOG" 2>/dev/null | grep -v '"phase":"run"' || true)
    [[ -n "$lines" ]] || return 0    # nothing ran (e.g. exited before any phase)
    RUN_SUMMARY_EMITTED=1            # mark emitted (read by the finish trap so it doesn't re-emit)

    local overall kv=()
    if command -v jq >/dev/null 2>&1; then
        overall=$(jq -rs 'if any(.[];.status=="fail") then "fail" elif any(.[];.status=="degraded") then "degraded" else "ok" end' <<<"$lines")
        # _f PHASE FIELD, first value of FIELD across this run's lines for PHASE
        _f() { jq -rs --arg p "$1" --arg f "$2" '[.[]|select(.phase==$p)|.[$f]//""]|.[0]//""' <<<"$lines"; }
        kv=(
            "backup_status=$(_f backup status)"
            "backup_size=$(_f backup size)"
            "images_updated=$(_f docker-update images_updated)"
            "pull_failures=$(_f docker-update pull_failures)"
            "apt_upgraded=$(_f system-update apt_upgraded)"
            "apt_count=$(_f system-update apt_upgraded_count)"
            "reboot_status=$(_f reboot status)"
            "age_update=$(_f backup age_update)"
            "minisign_update=$(_f backup minisign_update)"
        )
    else
        if   grep -q '"status":"fail"'     <<<"$lines"; then overall="fail"
        elif grep -q '"status":"degraded"' <<<"$lines"; then overall="degraded"
        else overall="ok"; fi
        warn "jq not found, run summary omits the per-phase lists"
    fi
    # vw_sev: a non-static field the maint rules match on. Wazuh reserves
    # "status" as a static decoder field that <field> can't match, so the
    # rules key on this instead, info when the overall is ok, else warn.
    local sev="info"; [[ "$overall" != "ok" ]] && sev="warn"
    kv+=("vw_sev=$sev")
    emit_status "run" "$overall" "$rc" "${kv[@]}"
}

# ---- locking --------------------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%H:%M:%S')] [main.sh] $(explain_exit_code 1)" | tee -a "$PHASE_LOG" >&2
    exit 1
fi
# On ANY exit (normal, backup-abort, etc.): roll up the run summary, then
# release the lock. Emitting the summary from the trap guarantees the
# nightly Discord report still fires even when backup fails and we abort
# early (the most important night to hear about).
finish() {
    local rc=$?
    # The normal path emits the run summary explicitly before the reboot
    # (so the agent ships it before the box goes down). Only emit from here
    # if that didn't happen , e.g. a backup failure aborted the run before
    # we got there , so the failure still gets reported.
    [[ -n "${RUN_SUMMARY_EMITTED:-}" ]] || emit_run_summary "$rc"
    rm -f "$LOCK_FILE"
}
trap finish EXIT

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
    log "phase: ${label}, running ${script##*/}"
    local rc=0
    "$script" || rc=$?
    if (( rc == 0 )); then
        log "phase: ${label}, OK"
    else
        log "phase: ${label}, FAILED $(explain_exit_code "$rc")"
    fi
    return "$rc"
}

# ---- phase 1: backup (mandatory) -----------------------------------------

if run_phase "backup" "${SCRIPTS_DIR}/backup.sh"; then
    BACKUP_OK=1
else
    RC=$?
    log "aborting maintenance run, backup is non-negotiable"
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
# The backup is the thing that actually matters; a failed update cycle
# does not invalidate the signal that the backup ran.

(( BACKUP_OK == 1 )) && deadman_ping

# ---- run summary (emitted BEFORE the reboot) -----------------------------
# Roll up + emit the run summary NOW, while the VM is fully up and the
# Wazuh agent is alive, so the agent ships it to the manager before
# reboot.sh takes the box down. Emitting it from the finish trap (after
# reboot.sh) loses a race with the shutdown: a bash EXIT trap doesn't run
# on the SIGTERM/SIGHUP a reboot delivers, and even if the line is written
# the agent gets stopped before it ships. That race ate the first real
# run's Discord summary. reboot.sh's 5s pre-reboot sleep is the shipping
# window; the reboot hasn't happened yet, so it reads "scheduled" here.
emit_run_summary 0

# ---- phase 4: reboot (always) --------------------------------------------

REBOOT_OK=0
# reboot.sh always reboots unless a safety gate (containers still running
# or apt/dpkg lock held) blocks it. On a successful reboot, /sbin/reboot
# replaces the process and we never return here.
if run_phase "reboot" "${SCRIPTS_DIR}/reboot.sh"; then
    REBOOT_OK=1
else
    # Non-zero = the safety gate BLOCKED the reboot. We did NOT reboot and
    # the containers are stopped (backup/docker left them down), so
    # Vaultwarden is DOWN. The summary above already shipped as "scheduled",
    # so fire a separate loud alert to correct it , the one case where not
    # rebooting is an emergency, not a relief.
    REBOOT_RC=$?
    emit_status run fail "$REBOOT_RC" "vw_sev=warn" "reboot_status=BLOCKED" "backup_status=ok"
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

# Retention on the orchestrator log. The JSON status log is a single file
# rotated host-side by logrotate (copytruncate), see README Log Rotation.
find "$MAIN_LOG_DIR" -name "main-*.log" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true

exit 0
