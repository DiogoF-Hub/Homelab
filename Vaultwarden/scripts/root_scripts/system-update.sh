#!/usr/bin/env bash
#
# system-update.sh: apt update / upgrade / dist-upgrade / autoremove /
# clean on the VM. Ensures unattended-upgrades is installed + enabled so
# security patches still land between manual runs. Preserves sshd_config
# on openssh-server upgrades (UCF_FORCE_CONFFOLD=1) so an unattended run
# cannot lock us out of the VM by overwriting hardened sshd settings.
#
# Runnable standalone:   sudo /root/vault/system-update.sh
# Called from main.sh:   /root/vault/system-update.sh
#
# Exit codes (see EXIT_CODE_DESC in lib.sh):
#   30: dpkg --configure -a failed
#   31: apt-get update failed
#   32: apt-get upgrade failed
#   33: apt-get dist-upgrade failed

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

PHASE_LOG="$SYSTEM_LOG"

require_root
require_cmd apt-get
require_cmd dpkg

ensure_log_dirs

{
    echo
    echo "================================================"
    echo "System update started at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "system-update starting"

export DEBIAN_FRONTEND=noninteractive

# --- dpkg state sanity ----------------------------------------------------

log "fixing any pending dpkg state (dpkg --configure -a)"
dpkg --configure -a >> "$PHASE_LOG" 2>&1 \
    || fail "dpkg --configure -a failed" 30

# --- apt update -----------------------------------------------------------

log "apt-get update"
apt-get update -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get update failed" 31

# --- unattended-upgrades --------------------------------------------------

log "ensuring unattended-upgrades is installed + enabled"
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    apt-get install -y unattended-upgrades >> "$PHASE_LOG" 2>&1 \
        || warn "failed to install unattended-upgrades, continuing"
fi
dpkg-reconfigure -f noninteractive unattended-upgrades >> "$PHASE_LOG" 2>&1 || true
systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
    >> "$PHASE_LOG" 2>&1 || true

# --- openssh-server special case ------------------------------------------
# Upgrade openssh-server while keeping existing sshd_config.
# UCF_FORCE_CONFFOLD=1: if the maintainer's new default conflicts with our
# local hardened config, KEEP the local copy. Losing our sshd_config on an
# unattended run would lock us out of the VM.

log "upgrading openssh-server (keeping existing config)"
UCF_FORCE_CONFFOLD=1 apt-get install --only-upgrade openssh-server -y \
    >> "$PHASE_LOG" 2>&1 \
    || warn "openssh-server upgrade had issues, review log"

# --- main upgrades --------------------------------------------------------

log "apt-get upgrade"
apt-get upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get upgrade failed" 32

log "apt-get dist-upgrade"
apt-get dist-upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get dist-upgrade failed" 33

# --- cleanup --------------------------------------------------------------

log "apt autoremove + clean"
apt-get autoremove --purge -y >> "$PHASE_LOG" 2>&1 || true
apt-get clean >> "$PHASE_LOG" 2>&1 || true

# --- retention -------------------------------------------------------------

log "applying retention (${RETENTION_DAYS} days)"
find "$SYSTEM_LOG_DIR" -name "system-autoupdate-*.log" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true

{
    echo "================================================"
    echo "System update finished at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "system-update complete"
exit 0
