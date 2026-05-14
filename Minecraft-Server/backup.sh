#!/bin/bash

# 1. Variables
SERVER_DIR="/home/main/server"
DATA_DIR="$SERVER_DIR/data"
BACKUP_DIR="$SERVER_DIR/backups"
LOG_DIR="$SERVER_DIR/logs"
CONTAINER="minecraft"
COMPOSE="docker compose -f $SERVER_DIR/docker-compose.yml"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/backup-$(date +"%Y-%m-%d").log"
BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.tar.gz"

# 2. Create log dir if not exists
mkdir -p "$LOG_DIR"

# 3. Redirect all output to log file
exec >> "$LOG_FILE" 2>&1

# 4. Delete logs older than 30 days
find "$LOG_DIR" -name "backup-*.log" -mtime +30 -delete

# 5. Warn players before stopping
echo "[$TIMESTAMP] Warning players..."
docker exec $CONTAINER rcon-cli "say Server stopping for backup in 5 minutes"
sleep 180

docker exec $CONTAINER rcon-cli "say Server stopping for backup in 2 minutes"
sleep 60

docker exec $CONTAINER rcon-cli "say Server stopping for backup in 60 seconds"
sleep 50

docker exec $CONTAINER rcon-cli "say Server stopping for backup in 10 seconds"
sleep 10

# 6. Stop the container
echo "[$TIMESTAMP] Stopping container..."
$COMPOSE down

# 7. Create compressed backup
echo "[$TIMESTAMP] Compressing data folder..."
tar -czf "$BACKUP_FILE" "$DATA_DIR"

# 8. Start the container again
echo "[$TIMESTAMP] Starting container..."
$COMPOSE up -d

# 9. Log result
echo "[$TIMESTAMP] Backup saved to $BACKUP_FILE"