# This script is used to do the maintenance tasks for a PiHole instance running on a Ubuntu Server VM in my Proxmox.
# It updates the gravity database, updates the instances (docker images) and performs a full system update while logging all actions to 3 different log files.


#! /bin/bash
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

cd "$COMPOSE_DIR" || { echo "[ERROR] Cannot access compose directory." | tee -a "$GRAVITY_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"; exit 1; }

# ======================
# 1. GRAVITY UPDATE
# ======================
{
echo "---------------------------------------------------------"
echo "Gravity Update started at: $(date)"
echo -e "---------------------------------------------------------\n"

echo "[→] Starting Gravity update..."
docker compose exec pihole pihole -g || {
    echo "[ERROR] Gravity update failed."
    exit 2
}

echo -e "[✔] Gravity list update completed successfully.\n"

echo -e "[→] Cleaning up logs older than $RETENTION_DAYS days...\n"
find "$GRAVITY_LOG_DIR" -type f -name "gravity-update-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

echo "---------------------------------------------------------"
echo "Gravity Update finished at: $(date)"
echo "---------------------------------------------------------"
} >> "$GRAVITY_LOG" 2>&1


# ======================
# 2. STOP CONTAINERS
# ======================
echo "[→] Stopping Pi-hole containers..." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
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
        echo "[✔] All containers are stopped." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "[ERROR] Timeout: Not all containers stopped after ${MAX_WAIT}s." | tee -a "$DOCKER_LOG" "$SYSTEM_LOG"
        exit 1
    fi
done


# ======================
# 3. DOCKER CONTAINER UPDATE
# ======================
{
    echo -e "\n---------------------------------------------------------"
    echo "Docker Container Update started at: $(date)"
    echo "---------------------------------------------------------"

    cd "$COMPOSE_DIR" || { echo "[ERROR] Cannot access compose directory."; exit 1; }

    UPDATED=0

    for service in $(docker compose config --services); do
        echo -e "\n[----- $service -----]"

        IMAGE=$(docker compose config | awk -v svc="$service" '$1 == svc ":" {in_service=1} in_service && $1 == "image:" {print $2; exit}')

        if [ -z "$IMAGE" ]; then
            echo "[WARN] Could not determine image for service $service."
            continue
        fi

        LOCAL_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)
        for attempt in {1..3}; do
            if docker pull "$IMAGE"; then
            break
            else
            echo -e "\n[WARN] docker pull failed for $IMAGE (attempt $attempt)." >&2
            sleep 2
            fi
        done
        LATEST_ID=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)

        if [ "$LOCAL_ID" != "$LATEST_ID" ]; then
            echo -e "\n[!!!] $service needs update."
            UPDATED=1
        else
            echo -e "\n[✔] $service is up-to-date."
        fi

        echo -e "[----- $service -----]"
    done

    if [ "$UPDATED" -eq 0 ]; then
        echo -e "\n[✔✔✔] No updates needed."
    fi

    echo -e "\n[→] Cleaning old logs..."
    find "$DOCKER_LOG_DIR" -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

    echo -e "\n---------------------------------------------------------"
    echo "Docker Container Update finished at: $(date)"
    echo "---------------------------------------------------------"
} >> "$DOCKER_LOG" 2>&1


# ======================
# 4. SYSTEM UPDATE
# ======================
{
echo -e "\n-----------------------------------------------------------"
echo "System Update started at: $(date)"
echo "-----------------------------------------------------------"

export DEBIAN_FRONTEND=noninteractive

echo -e "\n[→] Fixing broken packages..."
dpkg --configure -a

echo -e "\n[→] Updating package lists..."
apt-get update -y

# upgrade openssh-server while keeping existing configuration
echo -e "\n[→] Reinstalling openssh-server..."
UCF_FORCE_CONFFOLD=1 apt-get install --only-upgrade openssh-server -y

echo -e "\n[→] Upgrading packages..."
apt-get upgrade -y

echo -e "\n[→] Full upgrade (dist-upgrade)..."
apt-get full-upgrade -y

echo -e "\n[→] Cleaning up..."
apt-get autoremove --purge -y
apt-get clean

echo -e "\n[→] Cleaning old system logs..."
find "$SYSTEM_LOG_DIR" -type f -name "system-autoupdate-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

echo -e "\n-----------------------------------------------------------"
echo "System Update finished at: $(date)"
echo "-----------------------------------------------------------"
} >> "$SYSTEM_LOG" 2>&1

# ======================
# 5. FINAL REBOOT
# ======================
echo "[→] Maintenance complete. Rebooting..." | tee -a "$SYSTEM_LOG"
reboot -h now