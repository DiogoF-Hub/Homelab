#!/usr/bin/env bash
#
# auto-update.sh: nightly system update + unconditional reboot for the
# edge VPS. Run as root via cron.
#
# Phases (all in this one file; the VPS has no containers / no vault
# data to coordinate, so the multi-phase orchestrator pattern from the
# Vault VM doesn't earn its keep here):
#   - dpkg --configure -a       (clear any half-finished package state)
#   - apt-get update
#   - upgrade openssh-server with UCF_FORCE_CONFFOLD=1 so a maintainer
#     postinst can't overwrite the hardened /etc/ssh/sshd_config and
#     lock us out of the VPS. Deliberately done BEFORE the
#     unattended-upgrades setup below, because `systemctl enable --now
#     apt-daily-upgrade.timer` can trigger an immediate catch-up run
#     via Persistent=true if the timer missed its last scheduled fire;
#     doing the explicit openssh-server upgrade first guarantees our
#     UCF_FORCE_CONFFOLD=1 covers that package no matter what.
#   - ensure unattended-upgrades is installed + enabled
#   - apt-get upgrade
#   - apt-get dist-upgrade
#   - apt-get autoremove --purge + apt-get clean
#   - 30-day log retention
#   - sync + reboot
#
# Unconditional reboot policy mirrors the Vault VM's reboot.sh:
# /var/run/reboot-required only flags kernel / glibc / pid-1 changes,
# it misses cases like "openssl updated but nginx, crowdsec-firewall-
# bouncer, fail2ban are still using the in-memory copy". A few seconds
# of downtime per night is cheaper than reasoning about whether a
# reboot is really needed. needrestart deliberately not installed: it
# would only matter if we were trying to avoid the reboot.
#
# Logs land at /srv/logs/system/system-autoupdate-YYYY-MM-DD.log,
# 30-day retention. The log directory is world-readable so the
# unprivileged `fetcher` user can SCP the files (see vps/README.md
# section "Automated maintenance + log fetcher").
#
# Deploy to: /root/vps/auto-update.sh on the VPS.
# Cron entry: see ./root_crontab.txt.

set -euo pipefail

# ---- environment ---------------------------------------------------------

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ---- paths / retention ---------------------------------------------------

readonly TODAY="$(date '+%Y-%m-%d')"
readonly RETENTION_DAYS=30

readonly LOG_ROOT="/srv/logs"
readonly SYSTEM_LOG_DIR="${LOG_ROOT}/system"
readonly PHASE_LOG="${SYSTEM_LOG_DIR}/system-autoupdate-${TODAY}.log"

readonly LOCK_FILE="/var/run/vps-auto-update.lock"

# ---- helpers -------------------------------------------------------------

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$PHASE_LOG"
}

fail() {
    log "FATAL: $*"
    exit 1
}

# ---- preflight -----------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "auto-update.sh must run as root" >&2; exit 1; }

command -v flock     >/dev/null 2>&1 || fail "flock not found (apt install util-linux)"
command -v apt-get   >/dev/null 2>&1 || fail "apt-get not found"
command -v dpkg      >/dev/null 2>&1 || fail "dpkg not found"

mkdir -p "$SYSTEM_LOG_DIR"

# ---- single-instance lock ------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%H:%M:%S')] another auto-update run is already in progress, exiting" >&2
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT

# ---- header --------------------------------------------------------------

{
    echo
    echo "================================================"
    echo "VPS auto-update started at: $(date)"
    echo "Host: $(hostname)   PID: $$"
    echo "================================================"
} >> "$PHASE_LOG"

log "auto-update starting"

# ---- dpkg state sanity ---------------------------------------------------

log "fixing any pending dpkg state (dpkg --configure -a)"
dpkg --configure -a >> "$PHASE_LOG" 2>&1 \
    || fail "dpkg --configure -a failed"

# ---- apt update ----------------------------------------------------------

log "apt-get update"
apt-get update -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get update failed"

# ---- openssh-server special case (DO THIS FIRST) -------------------------
# Keep the hardened /etc/ssh/sshd_config across openssh-server upgrades.
# UCF_FORCE_CONFFOLD=1: if the maintainer's new default conflicts with our
# local hardened config, KEEP the local copy. Losing sshd_config on an
# unattended run could lock us out of the VPS.
#
# Deliberately runs BEFORE the unattended-upgrades enable below: the
# `systemctl enable --now apt-daily-upgrade.timer` line can trigger an
# immediate catch-up run via Persistent=true if the timer missed a
# scheduled fire while disabled, which could quietly pick up the
# openssh-server upgrade before our explicit flagged line. Doing the
# explicit upgrade first guarantees UCF_FORCE_CONFFOLD=1 covers this
# package regardless of any background apt activity that might follow.

log "upgrading openssh-server (keeping existing config)"
UCF_FORCE_CONFFOLD=1 apt-get install --only-upgrade openssh-server -y \
    >> "$PHASE_LOG" 2>&1 \
    || log "WARN: openssh-server upgrade had issues, review log"

# ---- unattended-upgrades -------------------------------------------------

log "ensuring unattended-upgrades is installed + enabled"
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    apt-get install -y unattended-upgrades >> "$PHASE_LOG" 2>&1 \
        || log "WARN: failed to install unattended-upgrades, continuing"
fi
dpkg-reconfigure -f noninteractive unattended-upgrades >> "$PHASE_LOG" 2>&1 || true
systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
    >> "$PHASE_LOG" 2>&1 || true

# ---- main upgrades -------------------------------------------------------

log "apt-get upgrade"
apt-get upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get upgrade failed"

log "apt-get dist-upgrade"
apt-get dist-upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get dist-upgrade failed"

# ---- cleanup -------------------------------------------------------------

log "apt autoremove + clean"
apt-get autoremove --purge -y >> "$PHASE_LOG" 2>&1 || true
apt-get clean                 >> "$PHASE_LOG" 2>&1 || true

# ---- log retention -------------------------------------------------------

log "applying retention (${RETENTION_DAYS} days)"
find "$SYSTEM_LOG_DIR" -name "system-autoupdate-*.log" -mtime +"$RETENTION_DAYS" -print -delete \
    >> "$PHASE_LOG" 2>&1 || true

# ---- reboot --------------------------------------------------------------

log "all phases done, REBOOT COMMAND being issued in 5 seconds"

{
    echo "================================================"
    echo "VPS auto-update finished at: $(date)"
    echo "STATUS: OK (rebooting)"
    echo "================================================"
} >> "$PHASE_LOG"

sync
sleep 5
exec /sbin/reboot -h now
