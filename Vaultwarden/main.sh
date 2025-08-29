# This script is used to do the maintenance tasks for a Vaultwarden instance running on a Raspberry Pi.
# It backs up the Vaultwarden data and it encrypts it using hybrid encryption, updates the instances (docker images), and performs a full system update while logging all actions to 3 different log files.

#! /bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === GLOBAL CONFIG ===
TODAY_DATE="$(date '+%Y-%m-%d')"

# Retention
# Logs and backups older than this number of days will be deleted
RETENTION_DAYS=30


# Paths
# Logs and backup are being saved in this dir (/srv) so with my truenas setup, I can easily retrieve them with another user which has access rights to this dir
MAIN_DIR="/srv"
COMPOSE_DIR="/home/pi/vault"

# Path to RSA public key (used to encrypt the AES key)
RSA_PUBLIC_KEY="${COMPOSE_DIR}/vaultwarden_public_key.pem"

# Data directory for Vaultwarden
vw_DATA_DIR="/vw-data"

LOG_DIR="${MAIN_DIR}/logs"
BACKUP_LOG_DIR="${LOG_DIR}/backup"
DOCKER_LOG_DIR="${LOG_DIR}/docker"
SYSTEM_LOG_DIR="${LOG_DIR}/system"

BACKUP_LOG="${BACKUP_LOG_DIR}/vault-backup-${TODAY_DATE}.log"
DOCKER_LOG="${DOCKER_LOG_DIR}/update-${TODAY_DATE}.log"
SYSTEM_LOG="${SYSTEM_LOG_DIR}/system-autoupdate-${TODAY_DATE}.log"

BACKUP_DIR="${MAIN_DIR}/backups"


# Ensure all log directories exist
mkdir -p "$BACKUP_LOG_DIR"
mkdir -p "$DOCKER_LOG_DIR"
mkdir -p "$SYSTEM_LOG_DIR"
mkdir -p "$BACKUP_DIR"


# ======================
# 1. STOP CONTAINERS
# ======================
echo "[->] Stopping all containers in Docker Compose stack..." | tee -a "$BACKUP_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"
cd "$COMPOSE_DIR" || { echo "[ERROR] Cannot access compose directory." | tee -a "$BACKUP_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"; exit 1; }
docker compose down 2>&1 | tee -a "$BACKUP_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"

# Wait for all services to be fully stopped
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
        echo "[OK] All containers are stopped." | tee -a "$BACKUP_LOG"
        break
    fi

    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "[ERROR] Timeout: Not all containers stopped after ${MAX_WAIT}s." | tee -a "$BACKUP_LOG"
        exit 1
    fi
done

# ======================
# 2. BACKUP
# ======================
{
    echo -e "\n-----------------------------------------------------------"
    echo "Vaultwarden Backup started at: $(date)"
    echo "-----------------------------------------------------------"

    ARCHIVE_NAME="vw-data-backup-${TODAY_DATE}.tar.gz"
    ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
    AES_KEY_FILE="${BACKUP_DIR}/aes-${TODAY_DATE}.key"

    ENCRYPTED_ARCHIVE="${ARCHIVE_PATH}.enc"
    ENCRYPTED_AES_KEY="${BACKUP_DIR}/aes-${TODAY_DATE}.key.enc"
    OPENSSL_VERSION_NOTE="${BACKUP_DIR}/openssl-version-${TODAY_DATE}.txt"

    FINAL_BUNDLE="${BACKUP_DIR}/vaultwarden-backup-bundle-${TODAY_DATE}.tar.gz"

    echo -e "\n[->] Creating backup archive..."
    tar -czvf "$ARCHIVE_PATH" -C "$vw_DATA_DIR" . || { echo "[ERROR] Backup archive creation failed!"; exit 1; }
    echo "[OK] Archive created at $ARCHIVE_PATH"

    echo -e "\n[->] Generating random AES-256 key..."
    openssl rand 32 > "$AES_KEY_FILE" || { echo "[ERROR] Failed to generate AES key."; exit 1; }

    # NOTE: AES-256-GCM not supported by 'openssl enc' — using AES-256-CBC instead
    echo -e "\n[->] Encrypting archive using AES-256-CBC..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -in "$ARCHIVE_PATH" -out "$ENCRYPTED_ARCHIVE" -pass file:"$AES_KEY_FILE"|| { echo "[ERROR] Archive encryption failed."; exit 1; }

    # NOTE: EC not supported by 'openssl pkeyutl' for encryption, using RSA instead
    echo -e "\n[->] Encrypting AES key using RSA public key..."
    openssl pkeyutl -encrypt -inkey "$RSA_PUBLIC_KEY" -pubin -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 -in "$AES_KEY_FILE" -out "$ENCRYPTED_AES_KEY" || { echo "[ERROR] AES key encryption failed."; exit 1; }

    echo -e "\n[->] Recording OpenSSL version only..."
    openssl version -a > "$OPENSSL_VERSION_NOTE" || true

    echo -e "\n[->] Packaging encrypted archive and key..."
    tar -czvf "$FINAL_BUNDLE" -C "$BACKUP_DIR" "$(basename "$ENCRYPTED_ARCHIVE")" "$(basename "$ENCRYPTED_AES_KEY")" "$(basename "$OPENSSL_VERSION_NOTE")" || { echo "[ERROR] Final bundle creation failed."; exit 1; }

    echo -e "\n[->] Cleaning up temporary files..."
    rm -f "$ARCHIVE_PATH" "$AES_KEY_FILE" "$ENCRYPTED_ARCHIVE" "$ENCRYPTED_AES_KEY" "$OPENSSL_VERSION_NOTE"

    echo -e "\n[OK] Final encrypted backup bundle stored at $FINAL_BUNDLE."

    echo -e "\n[->] Cleaning old backups and logs..."
    find "$BACKUP_DIR" -maxdepth 1 -name "vaultwarden-backup-bundle-*.tar.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
    find "$BACKUP_LOG_DIR" -name "vault-backup-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

    echo -e "\n-----------------------------------------------------------"
    echo "Vaultwarden Backup finished at: $(date)"
    echo "-----------------------------------------------------------"
} >> "$BACKUP_LOG" 2>&1


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
            echo -e "\n[OK] $service is up-to-date."
        fi

        echo -e "[----- $service -----]"
    done

    if [ "$UPDATED" -eq 0 ]; then
        echo -e "\n[*] No updates needed."
    fi

    echo -e "\n[->] Cleaning old logs..."
    find "$DOCKER_LOG_DIR" -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

    echo -e "\n---------------------------------------------------------"
    echo "Docker Container Update finished at: $(date)"
    echo "---------------------------------------------------------"
} >> "$DOCKER_LOG" 2>&1


# ======================
# 4. SYSTEM UPDATE (with real-time output)
# ======================
{
    echo -e "\n-----------------------------------------------------------"
    echo "System Update started at: $(date)"
    echo "-----------------------------------------------------------"

    export DEBIAN_FRONTEND=noninteractive

    echo -e "\n[->] Fixing broken packages..."
    dpkg --configure -a

    echo -e "\n[->] Updating package lists..."
    apt-get update -y

    # upgrade openssh-server while keeping existing configuration
    echo -e "\n[->] Reinstalling openssh-server..."
    UCF_FORCE_CONFFOLD=1 apt-get install --only-upgrade openssh-server -y

    echo -e "\n[->] Upgrading packages..."
    apt-get upgrade -y

    echo -e "\n[->] Full upgrade (dist-upgrade)..."
    apt-get dist-upgrade -y

    echo -e "\n[->] Cleaning up..."
    apt-get autoremove --purge -y
    apt-get clean

    echo -e "\n[->] Cleaning old system logs..."
    find "$SYSTEM_LOG_DIR" -name "system-autoupdate-*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

    echo -e "\n-----------------------------------------------------------"
    echo "System Update finished at: $(date)"
    echo "-----------------------------------------------------------"
} 2>&1 | tee -a "$SYSTEM_LOG"


# ======================
# 5. FINAL REBOOT
# ======================
echo "[->] Maintenance complete. Rebooting..." | tee -a "$SYSTEM_LOG"
reboot -h now