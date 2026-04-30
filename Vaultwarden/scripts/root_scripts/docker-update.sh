#!/usr/bin/env bash
#
# docker-update.sh: pull newer container images for every service defined
# in the compose file, remove obsolete image IDs, log what changed.
# Containers are left stopped at the end; they auto-start on boot via
# start-containers.sh (or equivalent unit).
#
# Runnable standalone:   sudo /root/vault/docker-update.sh
# Called from main.sh:   /root/vault/docker-update.sh
#
# Exit codes (see EXIT_CODE_DESC in lib.sh):
#   20: cannot access compose dir / stop containers failed
#   21: image pull failed after retries (treated as non-fatal: logged,
#        but this script still exits 0 so main.sh continues)

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

PHASE_LOG="$DOCKER_LOG"

require_root
require_cmd podman

ensure_log_dirs

{
    echo
    echo "================================================"
    echo "Container update started at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "docker-update starting"

# write_block LINE1 [LINE2 ...]: emit a tightly-grouped multi-line block
# to PHASE_LOG, with a single blank line above it (matching log()'s
# rhythm) but NO blank lines between internal lines, so banners read as
# one visual unit on a phone screen.
write_block() {
    local ts="[$(date '+%H:%M:%S')]"
    {
        printf '\n'
        local line
        for line in "$@"; do
            printf '%s %s\n' "$ts" "$line"
        done
    } | tee -a "$PHASE_LOG"
}

# --- stop containers (idempotent) -----------------------------------------

stop_containers

# --- per-service image refresh --------------------------------------------

cd "$COMPOSE_DIR" || fail "cannot access compose directory: $COMPOSE_DIR" 20

UPDATED=0
PULL_FAILURES=0
UPDATED_SERVICES=()
SERVICES=$(sudo -u "$USER_POD" podman-compose config --services 2>/dev/null || true)

if [[ -z "$SERVICES" ]]; then
    warn "no services declared in compose, nothing to update"
else
    for service in $SERVICES; do
        log "[$service] checking for newer image"

        IMAGE=$(sudo -u "$USER_POD" podman-compose config 2>/dev/null \
            | awk -v svc="$service" '$1 == svc ":" {in_service=1} in_service && $1 == "image:" {print $2; exit}')

        if [[ -z "$IMAGE" ]]; then
            warn "[$service] could not resolve image name, skipping"
            continue
        fi

        LOCAL_ID=$(sudo -u "$USER_POD" podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)

        # Retry pull up to 3 times for transient network / registry flakes.
        pulled=false
        for attempt in 1 2 3; do
            if sudo -u "$USER_POD" podman pull "docker.io/$IMAGE" >> "$PHASE_LOG" 2>&1; then
                pulled=true
                break
            else
                warn "[$service] podman pull failed (attempt $attempt)"
                sleep 2
            fi
        done

        if ! $pulled; then
            warn "[$service] pull FAILED after 3 attempts, next run will retry"
            PULL_FAILURES=$((PULL_FAILURES + 1))
            continue
        fi

        LATEST_ID=$(sudo -u "$USER_POD" podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
        if [[ "$LOCAL_ID" != "$LATEST_ID" ]]; then
            # Strip any "sha256:" prefix defensively (podman version drift),
            # then re-add it ourselves so the banner is consistent.
            old_full="${LOCAL_ID#sha256:}"
            new_full="${LATEST_ID#sha256:}"
            old_short="${old_full:0:12}"
            new_short="${new_full:0:12}"

            if [[ -z "$LOCAL_ID" ]]; then
                write_block \
                    "========== UPDATED: $service ==========" \
                    "  old: (none, first pull)" \
                    "  new: sha256:$new_full"
                UPDATED_SERVICES+=("$service (none -> $new_short)")
            else
                write_block \
                    "========== UPDATED: $service ==========" \
                    "  old: sha256:$old_full" \
                    "  new: sha256:$new_full"
                UPDATED_SERVICES+=("$service ($old_short -> $new_short)")
            fi

            UPDATED=$((UPDATED + 1))
            if [[ -n "$LOCAL_ID" ]]; then
                sudo -u "$USER_POD" podman rmi -f "$LOCAL_ID" >> "$PHASE_LOG" 2>&1 \
                    || warn "[$service] failed to remove old image $LOCAL_ID"
            fi
        else
            log "[$service] up-to-date"
        fi
    done

    # Always emit the summary banner. Consistent format means you always
    # know where to look at the bottom of the log, even on quiet runs.
    SUMMARY_LINES=(
        "====================================="
        "SUMMARY: $UPDATED image(s) UPDATED, $PULL_FAILURES failure(s)"
    )
    for entry in "${UPDATED_SERVICES[@]}"; do
        SUMMARY_LINES+=(" *$entry")
    done
    SUMMARY_LINES+=("=====================================")
    write_block "${SUMMARY_LINES[@]}"
fi

# --- retention -------------------------------------------------------------

log "applying retention (${RETENTION_DAYS} days)"
find "$DOCKER_LOG_DIR" -name "update-*.log" -mtime +"$RETENTION_DAYS" -print -delete >> "$PHASE_LOG" 2>&1 || true

{
    echo "================================================"
    echo "Container update finished at: $(date)"
    echo "================================================"
} >> "$PHASE_LOG"

log "docker-update complete"

# Pull failures are logged but non-fatal; next run retries. Exit 0 so the
# orchestrator continues on to system-update.
exit 0
