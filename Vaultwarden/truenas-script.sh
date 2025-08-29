# This script is used to automate the backup and logs files retrieval from the Raspberry Pi to the TrueNAS server and sending it to a Hetzner Storage Box in the cloud.
# IPs and user are changed from the original script

#! /bin/bash

# === CONFIGURATION ===
PI_USER="mainuser"
PI_HOST="192.168.123.4"
SSH_KEY="/root/.ssh/mainuser_automation_rsa"

RETENTION_DAYS=90
TODAY=$(date +"%Y-%m-%d")

# Remote paths on the Pi
REMOTE_BASE_LOG="/srv/logs"
REMOTE_BASE_BACKUP="/srv/backups"
REMOTE_BACKUP_LOG="${REMOTE_BASE_LOG}/backup/vault-backup-${TODAY}.log"
REMOTE_DOCKER_LOG="${REMOTE_BASE_LOG}/docker/update-${TODAY}.log"
REMOTE_SYSTEM_LOG="${REMOTE_BASE_LOG}/system/system-autoupdate-${TODAY}.log"
REMOTE_BACKUP_FILE="${REMOTE_BASE_BACKUP}/vaultwarden-backup-bundle-${TODAY}.tar.gz"

# Destination paths on TrueNAS
DEST_MAIN="/mnt/Main"
DEST_BACKUP_FILE="${DEST_MAIN}/Backups/vaultwarden"
DEST_DOCKER_LOG="${DEST_MAIN}/Logs/vaultwarden/docker"
DEST_BACKUP_LOG="${DEST_MAIN}/Logs/vaultwarden/backup"
DEST_SYSTEM_LOG="${DEST_MAIN}/Logs/vaultwarden/system"

DEST_HETZNER_LOG_DIR="${DEST_MAIN}/Logs/vaultwarden/Hetzner"
LOG_FILE="${DEST_HETZNER_LOG_DIR}/hetzner-upload-${TODAY}.log"

# === HETZNER UPLOAD CONFIGURATION ===
HETZNER_USER="bla1234"
HETZNER_HOST="bla1234.your-storagebox.de"
HETZNER_PORT=23
HETZNER_KEY="/root/.ssh/id_ed25519-hetzner-truenas"
HETZNER_DEST_DIR="/home/vaultwarden_backups"

rclone_config="/root/.config/rclone/rclone.conf"
RCLONE_PATH="hetzner_box"

# === LOGGING SETUP ===
mkdir -p "$DEST_HETZNER_LOG_DIR"

# === MAIN SCRIPT WITH LOGGING ===
{
    echo "-----------------------------------------------------------"
    echo "Hetzner Upload Script started at: $(date)"
    echo -e "-----------------------------------------------------------\n"

    fix_permissions() {
        local target_dir="$1"
        local filename="$2"
        local full_path="${target_dir}/${filename}"

        if [[ -f "$full_path" ]]; then
            chown vaultwarden_user:vms_group "$full_path"
            chmod 644 "$full_path"
            echo "[OK] Permissions fixed for $full_path"
        else
            echo "[SKIP] File not found to fix permissions: $full_path"
        fi
    }

    copy_file() {
        local remote_path="$1"
        local dest_dir="$2"
        local filename
        filename=$(basename "$remote_path")

        mkdir -p "$dest_dir"
        scp -i "$SSH_KEY" "${PI_USER}@${PI_HOST}:${remote_path}" "$dest_dir/"
        if [[ $? -eq 0 ]]; then
            echo -e "\n[OK] Fetched $filename to $dest_dir"
            fix_permissions "$dest_dir" "$filename"
        else
            echo -e "\n[SKIP] File not found on Pi: $filename"
        fi
    }

    cleanup_old_files() {
        echo -e "\n[→] Cleaning up old local log & backup files..."
        find "$DEST_BACKUP_LOG" -type f -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;
        find "$DEST_BACKUP_FILE" -type f -name "*.tar.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
        find "$DEST_DOCKER_LOG" -type f -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;
        find "$DEST_SYSTEM_LOG" -type f -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;

        find "$DEST_HETZNER_LOG_DIR" -type f -name "*.log" -mtime +$RETENTION_DAYS -exec rm -f {} \;
    }

    echo -e "\n[→] Fetching backup and log files..."
    copy_file "$REMOTE_BACKUP_LOG" "$DEST_BACKUP_LOG"
    copy_file "$REMOTE_BACKUP_FILE" "$DEST_BACKUP_FILE"
    copy_file "$REMOTE_DOCKER_LOG" "$DEST_DOCKER_LOG"
    copy_file "$REMOTE_SYSTEM_LOG" "$DEST_SYSTEM_LOG"

    local_file_path="${DEST_BACKUP_FILE}/vaultwarden-backup-bundle-${TODAY}.tar.gz"

    echo -e "\n[→] Preparing to upload backup to Hetzner Storage Box..."

    echo -e "\n[→] Checking available space on Hetzner Storage Box..."
    remote_free_output=$(ssh -p $HETZNER_PORT -i "$HETZNER_KEY" ${HETZNER_USER}@${HETZNER_HOST} "df /")
    remote_free_kb=$(echo "$remote_free_output" | awk 'NR==2 {print $4}')

    local_file_bytes=$(stat -c%s "$local_file_path")
    local_file_kb=$(( (local_file_bytes + 1023) / 1024 ))

    echo "[DEBUG] Local file size: ${local_file_kb} KB"
    echo "[DEBUG] Remote free space: ${remote_free_kb} KB"

    if [[ $remote_free_kb -lt $local_file_kb ]]; then
        echo -e "\n[ERROR] Not enough space on Hetzner Storage Box. Skipping upload."
    else
        echo -e "\n[→] Uploading backup to Hetzner Storage Box..."
        rclone copy $local_file_path $RCLONE_PATH:$HETZNER_DEST_DIR --config "$rclone_config" --progress
        if [[ $? -eq 0 ]]; then
            echo "[OK] Uploaded backup to Hetzner: ${HETZNER_DEST_DIR}/$(basename "$local_file_path")"

            echo -e "\n[→] Cleaning up old backups on Hetzner (keeping latest $RETENTION_DAYS days)..."
            rclone delete --min-age ${RETENTION_DAYS}d $RCLONE_PATH:$HETZNER_DEST_DIR

            echo -e "\n[→] Cleaning up older files than $RETENTION_DAYS days..."
            cleanup_old_files
        else
            echo -e "\n[ERROR] Failed to upload backup to Hetzner, not deleting older backups in remote."
        fi
    fi

    echo -e "\n-----------------------------------------------------------"
    echo "Hetzner Upload Script finished at: $(date)"
    echo -e "-----------------------------------------------------------\n"

} >> "$LOG_FILE" 2>&1

# Set permissions on the log file
chown vaultwarden_user:vms_group "$LOG_FILE"
chmod 644 "$LOG_FILE"