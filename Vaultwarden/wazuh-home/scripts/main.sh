#!/bin/bash
#
# main.sh: nightly OS update for wazuh-home (manager + indexer + dashboard).
# Run by root's cron. apt update / full-upgrade / autoremove / clean, log to
# the TrueNAS share, and reboot only when the update needs it (a package
# wrote /var/run/reboot-required, or needrestart sees a newer kernel than
# the running one).
#
# The Wazuh packages (wazuh-manager, wazuh-indexer, wazuh-dashboard,
# filebeat) are apt-held, so this never upgrades them; they're upgraded by
# hand with ../UPGRADE.md, manager host first, then the agents.
#
# Every upgrade keeps locally edited config files (dpkg --force-confold)
# instead of stopping at dpkg's keep-or-replace prompt. dpkg logs each kept
# file to /var/log/dpkg.log, which the manager reads, so it shows up in
# #config-files on Discord (rule 100601).
#
# Each run ends with one JSON status line for Wazuh -> Discord: the manager
# reads it like any agent's (localfile on /var/log/maint-status.jsonl),
# rules 100510-100512, #maintenance in the Wazuh category.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

# === GLOBAL CONFIG ===
TODAY_DATE="$(date '+%Y-%m-%d')"

# Retention
# Logs and backups older than this number of days will be deleted
RETENTION_DAYS=30

# Paths
MOUNT_POINT="/mnt/truenas-logs"
LOG_DIR="${MOUNT_POINT}/wazuh"
SYSTEM_LOG_DIR="${LOG_DIR}/system"
SYSTEM_LOG="${SYSTEM_LOG_DIR}/system-autoupdate-${TODAY_DATE}.log"

# Lock file to prevent concurrent runs
LOCK_FILE="/var/run/autoupdate.lock"

# === LOCK ===
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another instance is already running. Exiting." >&2
    exit 1
fi

# === NIGHTLY STATUS (Wazuh -> Discord) ===
# One JSON line per run in /var/log/maint-status.jsonl. The Wazuh agent
# ships it (a single, non-dated file, so the agent keeps its read position
# across the reboot), rules 100510-100512 fire on it, and custom-discord
# posts it to the #maintenance channel of this host's Discord category.
# status: ok | degraded (a step failed, the run went on) | fail (the run
# stopped early, or the host is left in a bad state).
MAINT_ROLE="wazuh"
MAINT_STATUS_FILE="/var/log/maint-status.jsonl"
MAINT_STEP="start"
MAINT_ERRORS=()
MAINT_FATAL=""
MAINT_EMITTED=""
MAINT_KV=()
MAINT_UPGRADABLE=()
MAINT_HELD_UPDATES=()

# maint_emit [key=value ...]: append the run's status line.
maint_emit() {
    local status="ok" sev="info" json kv key val
    (( ${#MAINT_ERRORS[@]} )) && status="degraded"
    [[ -n "$MAINT_FATAL" ]] && status="fail" && MAINT_ERRORS=("$MAINT_FATAL" "${MAINT_ERRORS[@]}")
    [[ "$status" != "ok" ]] && sev="warn"
    # maint_sev, not status, is what the rules match: Wazuh reserves
    # "status" as a static field a rule can't match with <field>.
    json=$(printf '{"event_type":"host_maint","role":"%s","host":"%s","ts":"%s","status":"%s","maint_sev":"%s"' \
        "$MAINT_ROLE" "$(hostname)" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$status" "$sev")
    for kv in "errors=$(IFS=';'; echo "${MAINT_ERRORS[*]}")" "${MAINT_KV[@]}" "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        json+=$(printf ',"%s":"%s"' "$key" "$val")
    done
    printf '%s}\n' "$json" >> "$MAINT_STATUS_FILE"
    MAINT_EMITTED=1
}

# Any exit before the normal end still reports, as a fail.
maint_on_exit() {
    local rc=$?
    if [[ -z "$MAINT_EMITTED" ]]; then
        MAINT_FATAL="${MAINT_FATAL:-run stopped early (exit $rc) during: $MAINT_STEP}"
        maint_emit
    fi
}

# maint_apt_snapshot: right after apt-get update, record what is about to
# be upgraded (held packages left out, they're never upgraded here) and
# which held packages have a newer version waiting (the Wazuh packages,
# upgraded by hand with wazuh-home/UPGRADE.md).
maint_apt_snapshot() {
    local held p inst cand
    mapfile -t held < <(apt-mark showhold 2>/dev/null)
    mapfile -t MAINT_UPGRADABLE < <(apt list --upgradable 2>/dev/null | grep '/' | cut -d/ -f1 \
        | grep -vxF -f <(printf '%s\n' "${held[@]}") || true)
    MAINT_HELD_UPDATES=()
    for p in "${held[@]}"; do
        inst=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null) || continue
        cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ {print $2}')
        if [[ -n "$cand" && "$cand" != "(none)" ]] && dpkg --compare-versions "$cand" gt "$inst"; then
            MAINT_HELD_UPDATES+=("$p → $cand")
        fi
    done
    MAINT_KV+=("apt_count=${#MAINT_UPGRADABLE[@]}"
               "apt_upgraded=$(IFS=,; echo "${MAINT_UPGRADABLE[*]}")"
               "held_updates=$(IFS=,; echo "${MAINT_HELD_UPDATES[*]}")")
}

# Set after the lock, so a second copy that just exits doesn't report.
trap maint_on_exit EXIT

# === WAIT FOR APT/DPKG LOCK ===
APT_LOCK_TIMEOUT=300
MAINT_STEP="waiting for the apt/dpkg lock"
echo "Waiting for apt/dpkg lock (up to ${APT_LOCK_TIMEOUT}s)..." >&2
if ! apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" -s check > /dev/null 2>&1; then
    echo "Could not acquire apt/dpkg lock after ${APT_LOCK_TIMEOUT}s. Aborting." >&2
    MAINT_FATAL="apt/dpkg lock still held after ${APT_LOCK_TIMEOUT}s, nothing was updated"
    exit 1
fi

# === VERIFY SMB MOUNT ===
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Mount $MOUNT_POINT is not mounted. Aborting." >&2
    MAINT_FATAL="TrueNAS log share $MOUNT_POINT not mounted, nothing was updated"
    exit 1
fi

# Ensure all log directories exist
mkdir -p "$SYSTEM_LOG_DIR"

# ======================
# 1. SYSTEM UPDATE
# ======================
export DEBIAN_FRONTEND=noninteractive
# needrestart (if installed) restarts services still running old libraries
# right after each apt run, without asking.
export NEEDRESTART_MODE=a

# Keep locally edited config files (rsyslog / logrotate drop-ins, sshd, ...)
# instead of stopping at dpkg's keep-or-replace prompt, which fails the
# package when nobody can answer. The maintainer's new version is saved as
# <file>.dpkg-dist.
APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Add spacing if appending to an existing log
if [ -s "$SYSTEM_LOG" ]; then
    echo -e "\n\n" >> "$SYSTEM_LOG"
fi

# From here on, stdout and stderr go to the log file
exec >> "$SYSTEM_LOG" 2>&1

echo -e "\n-----------------------------------------------------------"
echo "System Update started at: $(date)"
echo "-----------------------------------------------------------"

MAINT_STEP="system update"
echo -e "\n[->] Fixing broken packages..."
dpkg --configure -a || MAINT_ERRORS+=("dpkg --configure -a failed")

echo -e "\n[->] Updating package lists..."
if ! apt-get update -y; then
    echo "[✗] apt-get update failed. Aborting upgrades."
    MAINT_FATAL="apt-get update failed, nothing was upgraded"
    exit 1
fi
maint_apt_snapshot

# Upgrade openssh-server first, keeping existing config
echo -e "\n[->] Upgrading openssh-server (keeping config)..."
apt-get install --only-upgrade "${APT_CONF_OPTS[@]}" openssh-server -y \
    || MAINT_ERRORS+=("openssh-server upgrade failed")

# Held packages (the Wazuh stack) are listed as "kept back" and skipped;
# a newer version of them shows in the report (held_updates).
echo -e "\n[->] Full upgrade..."
apt-get "${APT_CONF_OPTS[@]}" full-upgrade -y || MAINT_ERRORS+=("apt-get full-upgrade failed")

echo -e "\n[->] Cleaning up..."
apt-get autoremove --purge -y
apt-get clean

echo -e "\n[->] Cleaning old system logs..."
find "$SYSTEM_LOG_DIR" -type f -name "system-autoupdate-*.log" -mtime +$RETENTION_DAYS -delete

echo -e "\n-----------------------------------------------------------"
echo "System Update finished at: $(date)"
echo "-----------------------------------------------------------"

# ======================
# 2. CONDITIONAL REBOOT
# ======================
# stdout is already redirected to $SYSTEM_LOG, so a plain echo is enough.
# Do NOT pipe through `tee -a "$SYSTEM_LOG"` here: tee would write to the file
# once via its own fd and once via its stdout (also the file) = duplicate line.
# On Debian the flag file alone isn't enough, a kernel update doesn't always
# write it, so also ask needrestart whether the newest installed kernel is
# the running one (KSTA 2/3 = a newer one is installed).
REBOOT_REASON=""
if [ -f /var/run/reboot-required ]; then
    REBOOT_REASON="reboot-required flag"
elif command -v needrestart > /dev/null 2>&1; then
    KSTA=$(needrestart -b -k 2>/dev/null | awk -F': ' '/^NEEDRESTART-KSTA/ {print $2}')
    if [ "$KSTA" = "2" ] || [ "$KSTA" = "3" ]; then
        REBOOT_REASON="newer kernel installed"
    fi
fi

MAINT_STEP="reboot check"
if [ -n "$REBOOT_REASON" ]; then
    echo "[->] Reboot required ($REBOOT_REASON). Rebooting..."
    # Report first. This host IS the manager: give it time to read the
    # line, match the rule and run custom-discord before the reboot stops
    # Wazuh.
    maint_emit "reboot=rebooting ($REBOOT_REASON)"
    sleep 15
    reboot -h now
else
    echo "[->] No reboot required."
    maint_emit "reboot=not needed"
fi
