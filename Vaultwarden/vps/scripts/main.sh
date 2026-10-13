#!/usr/bin/env bash
#
# main.sh: nightly system update for the edge VPS, rebooting only
# when the update needs it. Run as root via cron.
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
#     (every upgrade keeps locally edited config files, dpkg
#     --force-confdef --force-confold, instead of stopping at dpkg's
#     keep-or-replace prompt; the new default lands as <file>.dpkg-dist)
#   - apt-get autoremove --purge + apt-get clean
#   - 30-day log retention
#   - reboot only if needed: a package wrote /var/run/reboot-required,
#     or needrestart reports a newer kernel than the running one
#
# Reboot policy (same as the Pi-hole VM and wazuh-home): the VPS is the
# public edge, so every reboot takes the vault offline for a minute; it
# only reboots when the update needs it. The flag file alone isn't
# enough on Debian (a kernel update doesn't reliably write it), hence the
# needrestart kernel check. needrestart (NEEDRESTART_MODE=a) also
# restarts services still running old libraries right after each apt run
# (openssl updated -> nginx, fail2ban, crowdsec-firewall-bouncer, sshd),
# which is what makes skipping the reboot safe. Install it once:
# apt install needrestart. Without it, only the flag file counts.
#
# Logs land at /srv/logs/system/system-autoupdate-YYYY-MM-DD.log,
# 30-day retention. The log directory is world-readable so the
# unprivileged `fetcher` user can SCP the files (see vps/README.md
# section "Automated maintenance + log fetcher").
#
# Each run ends with one JSON status line in /var/log/maint-status.jsonl,
# the same as the Pi-hole VM and wazuh-home. It reaches Discord (#maintenance
# in the VPS category) once the VPS has a Wazuh agent; until then it's only
# written locally.
#
# Deploy to: /root/vps/main.sh on the VPS (mode 700, root).
# Cron entry: see ./root_crontab.txt.

set -euo pipefail

# ---- environment ---------------------------------------------------------

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
# needrestart restarts services still running old libraries after each
# apt run, without asking.
export NEEDRESTART_MODE=a

# Never stop at dpkg's "keep or replace this config file?" prompt. With no
# terminal the prompt fails the package mid-install and leaves dpkg half
# configured. confdef takes the maintainer's version only for files we never
# edited; confold keeps ours for the rest (nginx streams.d, fail2ban
# jail.local, the bouncer yaml, ...), and the maintainer's new version is
# saved next to it as <file>.dpkg-dist.
readonly APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

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
    MAINT_FATAL="$*"
    exit 1
}

# === NIGHTLY STATUS (Wazuh -> Discord) ===
# One JSON line per run in /var/log/maint-status.jsonl. The Wazuh agent
# ships it (a single, non-dated file, so the agent keeps its read position
# across the reboot), rules 100510-100512 fire on it, and custom-discord
# posts it to the #maintenance channel of this host's Discord category.
# status: ok | degraded (a step failed, the run went on) | fail (the run
# stopped early, or the host is left in a bad state).
MAINT_ROLE="vps"
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

# ---- preflight -----------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "main.sh must run as root" >&2; exit 1; }

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
# maint_on_exit first: it reads the exit code. Set after the lock, so a
# second copy that just exits doesn't report.
trap 'maint_on_exit; rm -f "$LOCK_FILE"' EXIT

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

MAINT_STEP="system update"
log "apt-get update"
apt-get update -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get update failed, nothing was upgraded"
maint_apt_snapshot

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
UCF_FORCE_CONFFOLD=1 apt-get "${APT_CONF_OPTS[@]}" install --only-upgrade openssh-server -y \
    >> "$PHASE_LOG" 2>&1 \
    || { log "WARN: openssh-server upgrade had issues, review log"; MAINT_ERRORS+=("openssh-server upgrade failed"); }

# ---- unattended-upgrades -------------------------------------------------

log "ensuring unattended-upgrades is installed + enabled"
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    apt-get install -y unattended-upgrades >> "$PHASE_LOG" 2>&1 \
        || { log "WARN: failed to install unattended-upgrades, continuing"; MAINT_ERRORS+=("unattended-upgrades install failed"); }
fi
dpkg-reconfigure -f noninteractive unattended-upgrades >> "$PHASE_LOG" 2>&1 || true
systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
    >> "$PHASE_LOG" 2>&1 || true

# ---- main upgrades -------------------------------------------------------

log "apt-get upgrade"
apt-get "${APT_CONF_OPTS[@]}" upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get upgrade failed"

log "apt-get dist-upgrade"
apt-get "${APT_CONF_OPTS[@]}" dist-upgrade -y >> "$PHASE_LOG" 2>&1 \
    || fail "apt-get dist-upgrade failed"

# ---- cleanup -------------------------------------------------------------

log "apt autoremove + clean"
apt-get autoremove --purge -y >> "$PHASE_LOG" 2>&1 || true
apt-get clean                 >> "$PHASE_LOG" 2>&1 || true

# ---- log retention -------------------------------------------------------

log "applying retention (${RETENTION_DAYS} days)"
find "$SYSTEM_LOG_DIR" -name "system-autoupdate-*.log" -mtime +"$RETENTION_DAYS" -print -delete \
    >> "$PHASE_LOG" 2>&1 || true

# ---- reboot (only if needed) --------------------------------------------
# A package flagged it (/var/run/reboot-required), or needrestart sees that
# the newest installed kernel isn't the running one (KSTA 2/3).

REBOOT_REASON=""
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REASON="reboot-required flag"
elif command -v needrestart >/dev/null 2>&1; then
    KSTA=$(needrestart -b -k 2>/dev/null | awk -F': ' '/^NEEDRESTART-KSTA/ {print $2}' || true)
    if [[ "$KSTA" == "2" || "$KSTA" == "3" ]]; then
        REBOOT_REASON="newer kernel installed"
    fi
fi

MAINT_STEP="reboot check"
if [[ -z "$REBOOT_REASON" ]]; then
    log "all phases done, no reboot needed"
    {
        echo "================================================"
        echo "VPS auto-update finished at: $(date)"
        echo "STATUS: OK (no reboot needed)"
        echo "================================================"
    } >> "$PHASE_LOG"
    maint_emit "reboot=not needed"
    exit 0
fi

log "all phases done, REBOOT ($REBOOT_REASON) being issued in 10 seconds"

{
    echo "================================================"
    echo "VPS auto-update finished at: $(date)"
    echo "STATUS: OK (rebooting: $REBOOT_REASON)"
    echo "================================================"
} >> "$PHASE_LOG"

# Report before the reboot; the 10 s give the Wazuh agent (once installed)
# time to ship the line before it gets stopped.
maint_emit "reboot=rebooting ($REBOOT_REASON)"
sync
sleep 10
exec /sbin/reboot -h now
