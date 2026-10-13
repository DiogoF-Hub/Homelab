#!/bin/bash

# This script is used to do the maintenance tasks for a PiHole instance running on a Debian 13 VM in my Proxmox.
# It updates the gravity database, updates the instances (docker images) and performs a full system update while logging all actions to 3 different log files.
# Then it reboots only if the update needs it (start-containers.sh brings the stack back @reboot); otherwise it starts the containers again itself.
# Each run ends with one JSON status line for Wazuh -> Discord (#maintenance in the Pi-Hole category).

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === GLOBAL CONFIG ===
TODAY_DATE="$(date '+%Y-%m-%d')"

# Retention
# Logs and backups older than this number of days will be deleted
RETENTION_DAYS=30

# Paths
COMPOSE_DIR="/home/pi/pihole"
LOG_DIR="/mnt/truenas-logs/pihole"
GRAVITY_LOG_DIR="${LOG_DIR}/gravity"
DOCKER_LOG_DIR="${LOG_DIR}/docker"
SYSTEM_LOG_DIR="${LOG_DIR}/system"

GRAVITY_LOG="${GRAVITY_LOG_DIR}/gravity-update-${TODAY_DATE}.log"
DOCKER_LOG="${DOCKER_LOG_DIR}/update-${TODAY_DATE}.log"
SYSTEM_LOG="${SYSTEM_LOG_DIR}/system-autoupdate-${TODAY_DATE}.log"

# Ensure all log directories exist
mkdir -p "$GRAVITY_LOG_DIR"
mkdir -p "$DOCKER_LOG_DIR"
mkdir -p "$SYSTEM_LOG_DIR"

# === NIGHTLY STATUS (Wazuh -> Discord) ===
# One JSON line per run in /var/log/maint-status.jsonl. The Wazuh agent
# ships it (a single, non-dated file, so the agent keeps its read position
# across the reboot), rules 100510-100512 fire on it, and custom-discord
# posts it to the #maintenance channel of this host's Discord category.
# status: ok | degraded (a step failed, the run went on) | fail (the run
# stopped early, or the host is left in a bad state).
MAINT_ROLE="pihole"
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

trap maint_on_exit EXIT

cd "$COMPOSE_DIR" || { MAINT_FATAL="cannot access $COMPOSE_DIR"; echo "[ERROR] Cannot access compose directory." | tee -a "$GRAVITY_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"; exit 1; }

# ======================
# 1. GRAVITY UPDATE
# ======================
MAINT_STEP="gravity update"
{
echo "---------------------------------------------------------"
echo "Gravity Update started at: $(date)"
echo -e "---------------------------------------------------------\n"

echo "[-->] Starting Gravity update..."
docker compose exec pihole pihole -g || {
    echo "[ERROR] Gravity update failed."
    MAINT_FATAL="gravity update (pihole -g) failed, nothing else was done"
    exit 2
}

echo -e "[OK] Gravity list update completed successfully.\n"

echo -e "[-->] Cleaning up logs older than $RETENTION_DAYS days...\n"
find "$GRAVITY_LOG_DIR" -type f -name "gravity-update-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

echo "---------------------------------------------------------"
echo "Gravity Update finished at: $(date)"
echo "---------------------------------------------------------"
} >> "$GRAVITY_LOG" 2>&1


# ======================
# 2. STOP CONTAINERS
# ======================
MAINT_STEP="stopping the containers"
echo "[-->] Stopping Pi-hole containers..." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
docker compose down 2>&1 | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"

# Wait for all services to stop
WAITED=0
MAX_WAIT=30
SERVICES=$(docker compose config --services)
while true; do
    ALL_STOPPED=true
    for service in $SERVICES; do
        CONTAINER_ID=$(docker ps -aqf "name=${service}")
        if [ -n "$CONTAINER_ID" ] && [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null)" == "true" ]; then
            ALL_STOPPED=false
            break
        fi
    done
    if $ALL_STOPPED; then
        echo "[OK] All containers are stopped." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "[ERROR] Timeout: Not all containers stopped after ${MAX_WAIT}s." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
        MAINT_FATAL="containers didn't stop within ${MAX_WAIT}s, check Pi-hole is answering DNS"
        exit 1
    fi
done


# ======================
# 3. DOCKER CONTAINER UPDATE
# ======================
MAINT_STEP="docker image update"
UPDATED_NAMES=()
PULL_FAILED=()
{
    echo -e "\n---------------------------------------------------------"
    echo "Docker Container Update started at: $(date)"
    echo "---------------------------------------------------------"

    cd "$COMPOSE_DIR" || { MAINT_FATAL="cannot access $COMPOSE_DIR"; echo "[ERROR] Cannot access compose directory."; exit 1; }

    UPDATED=0

    for service in $(docker compose config --services); do
        echo -e "\n[----- $service -----]"

        IMAGE=$(docker compose config | awk -v svc="$service" '$1 == svc ":" {in_service=1} in_service && $1 == "image:" {print $2; exit}')

        if [ -z "$IMAGE" ]; then
            echo "[WARN] Could not determine image for service $service."
            continue
        fi

        LOCAL_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)
        PULLED=false
        for attempt in {1..3}; do
            if docker pull "$IMAGE"; then
            PULLED=true
            break
            else
            echo -e "\n[WARN] docker pull failed for $IMAGE (attempt $attempt)." >&2
            sleep 2
            fi
        done
        $PULLED || PULL_FAILED+=("$service")
        LATEST_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)

        if [ "$LOCAL_ID" != "$LATEST_ID" ]; then
            echo -e "\n[!!!] $service needs update."
            UPDATED=1
            UPDATED_NAMES+=("$service")

            # Remove old image if it exists
            if [ -n "$LOCAL_ID" ]; then
                echo -e "\n[->] Removing old image $LOCAL_ID..."
                docker rmi -f "$LOCAL_ID" || echo "[WARN] Failed to remove old image $LOCAL_ID"
            fi
        else
            echo -e "\n[OK] $service is up-to-date."
        fi

        echo -e "[----- $service -----]"
    done

    if [ "$UPDATED" -eq 0 ]; then
        echo -e "\n[OK] No updates needed."
    fi

    echo -e "\n[-->] Cleaning old logs..."
    find "$DOCKER_LOG_DIR" -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

    echo -e "\n---------------------------------------------------------"
    echo "Docker Container Update finished at: $(date)"
    echo "---------------------------------------------------------"
} >> "$DOCKER_LOG" 2>&1

(( ${#PULL_FAILED[@]} )) && MAINT_ERRORS+=("docker pull failed: $(IFS=,; echo "${PULL_FAILED[*]}")")
MAINT_KV+=("images_updated=$(IFS=,; echo "${UPDATED_NAMES[*]}")" "pull_failures=$(IFS=,; echo "${PULL_FAILED[*]}")")


# ======================
# 4. SYSTEM UPDATE
# ======================
MAINT_STEP="system update"
{
echo -e "\n-----------------------------------------------------------"
echo "System Update started at: $(date)"
echo "-----------------------------------------------------------"

export DEBIAN_FRONTEND=noninteractive
# needrestart (if installed) restarts services still running old libraries
# right after each apt run, without asking.
export NEEDRESTART_MODE=a

# Keep locally edited config files (squid.conf, ...) instead of stopping at
# dpkg's keep-or-replace prompt, which fails the package when nobody can
# answer. The maintainer's new version is saved as <file>.dpkg-dist.
APT_CONF_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo -e "\n[-->] Fixing broken packages..."
dpkg --configure -a || MAINT_ERRORS+=("dpkg --configure -a failed")

echo -e "\n[-->] Updating package lists..."
if apt-get update -y; then
    maint_apt_snapshot
else
    MAINT_ERRORS+=("apt-get update failed")
fi

# upgrade openssh-server while keeping existing configuration
echo -e "\n[-->] Reinstalling openssh-server..."
UCF_FORCE_CONFFOLD=1 apt-get "${APT_CONF_OPTS[@]}" install --only-upgrade openssh-server -y \
    || MAINT_ERRORS+=("openssh-server upgrade failed")

echo -e "\n[-->] Upgrading packages..."
apt-get "${APT_CONF_OPTS[@]}" upgrade -y || MAINT_ERRORS+=("apt-get upgrade failed")

echo -e "\n[-->] Full upgrade (dist-upgrade)..."
apt-get "${APT_CONF_OPTS[@]}" full-upgrade -y || MAINT_ERRORS+=("apt-get full-upgrade failed")

echo -e "\n[-->] Cleaning up..."
apt-get autoremove --purge -y
apt-get clean

echo -e "\n[-->] Cleaning old system logs..."
find "$SYSTEM_LOG_DIR" -type f -name "system-autoupdate-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

echo -e "\n-----------------------------------------------------------"
echo "System Update finished at: $(date)"
echo "-----------------------------------------------------------"
} >> "$SYSTEM_LOG" 2>&1

# ======================
# 5. REBOOT OR RESTART THE STACK
# ======================
MAINT_STEP="reboot / restart"

# Reboot only when the update needs it: a package flagged it
# (/var/run/reboot-required), or needrestart sees that the newest installed
# kernel isn't the running one (KSTA 2/3). On Debian the flag file alone
# isn't enough, a kernel update doesn't always write it.
REBOOT_REASON=""
if [ -f /var/run/reboot-required ]; then
    REBOOT_REASON="reboot-required flag"
elif command -v needrestart > /dev/null 2>&1; then
    KSTA=$(needrestart -b -k 2>/dev/null | awk -F': ' '/^NEEDRESTART-KSTA/ {print $2}')
    if [ "$KSTA" = "2" ] || [ "$KSTA" = "3" ]; then
        REBOOT_REASON="newer kernel installed"
    fi
fi

if [ -n "$REBOOT_REASON" ]; then
    # start-containers.sh brings the stack back @reboot.
    echo "[-->] Maintenance complete. Rebooting ($REBOOT_REASON)..." | tee -a "$SYSTEM_LOG"
    # Report before the reboot, and give the Wazuh agent a few seconds to
    # ship the line before it gets stopped.
    maint_emit "reboot=rebooting ($REBOOT_REASON)" "containers=back at boot (start-containers.sh)"
    sleep 10
    reboot -h now
else
    # Same command as @reboot: --force-recreate puts the freshly pulled images live.
    echo "[-->] Maintenance complete. No reboot needed, starting containers..." | tee -a "$SYSTEM_LOG" "$DOCKER_LOG"
    if "$COMPOSE_DIR/start-containers.sh" >> "$DOCKER_LOG" 2>&1; then
        maint_emit "reboot=not needed" "containers=started"
    else
        echo "[ERROR] start-containers.sh failed, Pi-hole is DOWN." | tee -a "$SYSTEM_LOG" "$DOCKER_LOG"
        MAINT_FATAL="start-containers.sh failed, Pi-hole is DOWN (no LAN DNS)"
        maint_emit "reboot=not needed" "containers=start FAILED"
    fi
fi
