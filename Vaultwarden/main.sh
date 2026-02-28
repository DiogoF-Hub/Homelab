# This script is used to do the maintenance tasks for a Vaultwarden instance running on a VM.
# It backs up the Vaultwarden data and encrypts it using age public-key encryption, updates the instances (docker images), and performs a full system update while logging all actions to 3 different log files.

#! /bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === GLOBAL CONFIG ===
TODAY_DATE="$(date '+%Y-%m-%d')"

# Retention
# Logs and backups older than this number of days will be deleted
RETENTION_DAYS=30


# Paths
# Logs and backup are being saved in this dir (/srv) so with my truenas setup, I can easily retrieve them with another user which has access rights to this dir
USER_POD="poduser"
MAIN_DIR="/srv"
COMPOSE_DIR="/home/$USER_POD/vault"

# age encryption (pinned binary, never auto-updated)
# To update: run setup-age.sh with new version, then change AGE_VERSION here
AGE_VERSION="v1.3.1"
AGE_TOOLS_DIR="/srv/tools/age"
AGE_BINARY="${AGE_TOOLS_DIR}/${AGE_VERSION}/age"
AGE_BINARY_WIN="${AGE_TOOLS_DIR}/${AGE_VERSION}/age.exe"
AGE_RECIPIENT_FILE="/srv/age-recipient.txt"
DECRYPT_TXT="${COMPOSE_DIR}/DECRYPT.txt"

# Data directory for Vaultwarden
vw_DATA_DIR="/srv/vw-data"

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
sudo -u $USER_POD podman-compose down 2>&1 | tee -a "$BACKUP_LOG" "$DOCKER_LOG" "$SYSTEM_LOG"

# Wait for all services to be fully stopped
WAITED=0
MAX_WAIT=30
SERVICES=$(docker compose config --services)
while true; do
    ALL_STOPPED=true
    for service in $SERVICES; do
        CONTAINER_ID=$(sudo -u $USER_POD podman ps -aq --filter "name=${service}")
        if [ -n "$CONTAINER_ID" ] && [ "$(sudo -u $USER_POD podman inspect -f '{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null)" == "true" ]; then
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

    # --- Validate age prerequisites ---
    echo -e "\n[->] Validating age encryption prerequisites..."

    if [ ! -x "$AGE_BINARY" ]; then
        echo "[ERROR] age binary not found or not executable at $AGE_BINARY"
        echo "        Run setup-age.sh $AGE_VERSION to download it."
        exit 1
    fi

    if [ ! -f "$AGE_RECIPIENT_FILE" ]; then
        echo "[ERROR] age recipient file not found at $AGE_RECIPIENT_FILE"
        echo "        Generate a key pair on a separate machine and place the public key here."
        exit 1
    fi

    AGE_RECIPIENT=$(grep -m1 '^age1' "$AGE_RECIPIENT_FILE" || true)
    if [ -z "$AGE_RECIPIENT" ]; then
        echo "[ERROR] No valid age public key (age1...) found in $AGE_RECIPIENT_FILE"
        exit 1
    fi

    echo "[OK] Using age $AGE_VERSION with recipient ${AGE_RECIPIENT:0:20}..."

    # --- Create backup archive ---
    ARCHIVE_NAME="vw-data-backup-${TODAY_DATE}.tar.gz"
    ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
    ENCRYPTED_ARCHIVE="${ARCHIVE_PATH}.age"
    MANIFEST="${BACKUP_DIR}/manifest-${TODAY_DATE}.txt"
    BUNDLE_AGE_BINARY="${BACKUP_DIR}/age"
    BUNDLE_AGE_BINARY_WIN="${BACKUP_DIR}/age.exe"
    BUNDLE_DECRYPT_TXT="${BACKUP_DIR}/DECRYPT.txt"
    FINAL_BUNDLE="${BACKUP_DIR}/vaultwarden-backup-bundle-${TODAY_DATE}.tar.gz"

    echo -e "\n[->] Creating backup archive..."
    tar -czvf "$ARCHIVE_PATH" -C "$vw_DATA_DIR" . || { echo "[ERROR] Backup archive creation failed!"; exit 1; }
    echo "[OK] Archive created at $ARCHIVE_PATH"

    # --- Encrypt with age ---
    echo -e "\n[->] Encrypting archive with age (X25519 public-key encryption)..."
    "$AGE_BINARY" -r "$AGE_RECIPIENT" -o "$ENCRYPTED_ARCHIVE" "$ARCHIVE_PATH" || { echo "[ERROR] age encryption failed!"; exit 1; }
    echo "[OK] Encrypted archive created at $ENCRYPTED_ARCHIVE"

    # --- Generate manifest ---
    echo -e "\n[->] Generating manifest..."
    ARCHIVE_SHA256=$(sha256sum "$ENCRYPTED_ARCHIVE" | awk '{print $1}')
    AGE_BINARY_SHA256=$(sha256sum "$AGE_BINARY" | awk '{print $1}')
    AGE_BINARY_WIN_SHA256=$(sha256sum "$AGE_BINARY_WIN" | awk '{print $1}')
    {
        echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "age_version=$AGE_VERSION"
        echo "archive_sha256=$ARCHIVE_SHA256"
        echo "age_binary_sha256=$AGE_BINARY_SHA256"
        echo "age_binary_win_sha256=$AGE_BINARY_WIN_SHA256"
        echo "recipient_public_key=$AGE_RECIPIENT"
    } > "$MANIFEST"
    echo "[OK] Manifest written to $MANIFEST"

    # --- Prepare bundle contents ---
    echo -e "\n[->] Copying age binaries (Linux + Windows) and DECRYPT.txt into bundle..."
    cp "$AGE_BINARY" "$BUNDLE_AGE_BINARY"
    cp "$AGE_BINARY_WIN" "$BUNDLE_AGE_BINARY_WIN"
    if [ -f "$DECRYPT_TXT" ]; then
        cp "$DECRYPT_TXT" "$BUNDLE_DECRYPT_TXT"
    else
        echo "[WARN] DECRYPT.txt not found at $DECRYPT_TXT, skipping."
    fi

    # --- Create final self-contained bundle ---
    echo -e "\n[->] Packaging final backup bundle..."
    BUNDLE_FILES=("$(basename "$ENCRYPTED_ARCHIVE")" "$(basename "$MANIFEST")" "age" "age.exe")
    if [ -f "$BUNDLE_DECRYPT_TXT" ]; then
        BUNDLE_FILES+=("DECRYPT.txt")
    fi
    tar -czvf "$FINAL_BUNDLE" -C "$BACKUP_DIR" "${BUNDLE_FILES[@]}" || { echo "[ERROR] Final bundle creation failed."; exit 1; }

    # --- Clean up temporary files ---
    echo -e "\n[->] Cleaning up temporary files..."
    rm -f "$ARCHIVE_PATH" "$ENCRYPTED_ARCHIVE" "$MANIFEST" "$BUNDLE_AGE_BINARY" "$BUNDLE_AGE_BINARY_WIN" "$BUNDLE_DECRYPT_TXT"

    echo -e "\n[OK] Final encrypted backup bundle stored at $FINAL_BUNDLE"

    # --- Check for newer age version ---
    echo -e "\n[->] Checking for newer age releases..."
    LATEST_TAG=$(curl -sf --max-time 10 "https://api.github.com/repos/FiloSottile/age/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//' || true)
    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "$AGE_VERSION" ]; then
        echo "[WARN] age $LATEST_TAG is available (currently using $AGE_VERSION). Run setup-age.sh to download it."
    elif [ -n "$LATEST_TAG" ]; then
        echo "[OK] age $AGE_VERSION is the latest release."
    else
        echo "[WARN] Could not check for age updates (GitHub API unreachable)."
    fi

    # --- Retention cleanup ---
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

        IMAGE=$(sudo -u $USER_POD docker compose config | awk -v svc="$service" '$1 == svc ":" {in_service=1} in_service && $1 == "image:" {print $2; exit}')

        if [ -z "$IMAGE" ]; then
            echo "[WARN] Could not determine image for service $service."
            continue
        fi

        # Get currently installed image ID
        LOCAL_ID=$(sudo -u $USER_POD podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)

        # Pull the latest image (with retries)
        for attempt in {1..3}; do
            if sudo -u $USER_POD podman pull "docker.io/$IMAGE"; then
                break
            else
                echo -e "\n[WARN] podman pull failed for $IMAGE (attempt $attempt)." >&2
                sleep 2
            fi
        done

        # Get new image ID after pull
        LATEST_ID=$(sudo -u $USER_POD podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)

        # Compare image IDs
        if [ "$LOCAL_ID" != "$LATEST_ID" ]; then
            echo -e "\n[!!!] $service needs update."
            UPDATED=1

            # Remove old image if it exists
            if [ -n "$LOCAL_ID" ]; then
                echo -e "\n[->] Removing old image $LOCAL_ID..."
                sudo -u $USER_POD podman rmi -f "$LOCAL_ID" || echo "[WARN] Failed to remove old image $LOCAL_ID"
            fi
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

    echo -e "\n[->] Ensuring unattended-upgrades is installed..."
    if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
        apt-get install -y unattended-upgrades
    fi

    echo -e "\n[->] Configuring unattended-upgrades..."
    dpkg-reconfigure -f noninteractive unattended-upgrades
    systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

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