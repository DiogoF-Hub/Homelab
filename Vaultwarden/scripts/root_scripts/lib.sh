# lib.sh, shared constants and helpers for the maintenance scripts.
#
# This file is sourced by main.sh, backup.sh, docker-update.sh,
# system-update.sh, and reboot.sh. It must NEVER be executed directly,
# no top-level side effects beyond defining variables, readonly paths,
# and functions.
#
# Usage in callers (all of them co-located with this file in
# ${ROOT_VAULT_DIR}, `/root/vault/`, on the VM):
#     source "$(dirname "$(readlink -f "$0")")/lib.sh"

# ---- environment ---------------------------------------------------------

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8

# ---- dates / retention --------------------------------------------------

readonly TODAY_DATE="$(date '+%Y-%m-%d')"
readonly RETENTION_DAYS=30

# ---- who runs what ------------------------------------------------------

readonly USER_POD="poduser"
# COMPOSE_DIR is defined further down, it auto-derives from
# ROOT_VAULT_DIR's basename so /root/vault → /home/poduser/vault and
# /root/vault2 → /home/poduser/vault2 stay in lockstep.

# ---- data directories ---------------------------------------------------

readonly MAIN_DIR="/srv"
readonly VW_DATA_DIR="${MAIN_DIR}/vw-data"
readonly VW_LOGS_DIR="${MAIN_DIR}/vw-logs"
readonly BW_LOGS_DIR="${MAIN_DIR}/bw-logs"
readonly BACKUP_DIR="${MAIN_DIR}/backups"

# ---- log layout ---------------------------------------------------------
# Log filenames preserve the legacy names from the pre-split main.sh so any
# existing log-scraping / retention tooling keeps working unchanged:
#   backup/vault-backup-*.log           (unchanged)
#   docker/update-*.log                 (unchanged, now written by docker-update.sh)
#   system/system-autoupdate-*.log      (unchanged, now written by system-update.sh)
#   main/main-*.log                     (orchestrator + reboot phase events)

readonly LOG_ROOT="${MAIN_DIR}/logs"
readonly MAIN_LOG_DIR="${LOG_ROOT}/main"
readonly BACKUP_LOG_DIR="${LOG_ROOT}/backup"
readonly DOCKER_LOG_DIR="${LOG_ROOT}/docker"
readonly SYSTEM_LOG_DIR="${LOG_ROOT}/system"

readonly MAIN_LOG="${MAIN_LOG_DIR}/main-${TODAY_DATE}.log"
readonly BACKUP_LOG="${BACKUP_LOG_DIR}/vault-backup-${TODAY_DATE}.log"
readonly DOCKER_LOG="${DOCKER_LOG_DIR}/update-${TODAY_DATE}.log"
readonly SYSTEM_LOG="${SYSTEM_LOG_DIR}/system-autoupdate-${TODAY_DATE}.log"

# ---- maintenance status log (JSON, for Wazuh -> Discord) ----------------
# One JSON object per phase, plus a final `run` summary line, written by
# emit_status(). The Vault VM Wazuh agent tails it (event_type=vault_maint)
# and the manager turns the `run` event into a nightly Discord report.
# See wazuh-home/ + ideas.md #7 Phase A.
readonly STATUS_LOG_DIR="${LOG_ROOT}/status"
readonly STATUS_LOG="${STATUS_LOG_DIR}/vault-maint-status-${TODAY_DATE}.jsonl"

# ---- locking ------------------------------------------------------------

readonly LOCK_FILE="/var/run/vaultwarden-maint.lock"

# ---- root's maintenance vault -------------------------------------------
# Root-owned directory (mode 700) that holds everything the maintenance
# flow needs: the scripts themselves (main.sh, backup.sh, lib.sh, etc.)
# and the backup-crypto material (age recipient, minisign keypair).
# Populated during VM rebuild, see REBUILD.md (repo root).
# NOTE: unrelated to the Vaultwarden application vault. It's just the
# name of the directory where root keeps the maintenance toolkit.
#
# ROOT_VAULT_DIR auto-derives from where this file (lib.sh) actually
# sits, so the same code works under /root/vault, /root/vault2, or
# anything else (handy when staging a new layout side-by-side with the
# old one). Two supported layouts:
#
#   1. Flat (production layout, the canonical one):
#        /root/vault/lib.sh, /root/vault/main.sh, /root/vault/backup.sh, ...
#        → ROOT_VAULT_DIR = /root/vault
#
#   2. Repo-mirror (lib.sh sits inside a `root_scripts/` subdir, useful
#      when staging a new version side-by-side with the running one):
#        /root/vault2/root_scripts/lib.sh, ..., /root/vault2/setups_scripts/...
#        → ROOT_VAULT_DIR = /root/vault2  (the parent, where crypto
#          material like age-recipient.txt actually lives)
#
# If lib.sh ever gets relocated to a layout that's neither of these,
# update this branch.

__LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$__LIB_DIR")" == "root_scripts" ]]; then
    readonly ROOT_VAULT_DIR="$(dirname "$__LIB_DIR")"
else
    readonly ROOT_VAULT_DIR="$__LIB_DIR"
fi
unset __LIB_DIR

# COMPOSE_DIR, where poduser keeps the compose files. Mirrors the basename
# of ROOT_VAULT_DIR so the two stay in lockstep:
#   /root/vault       → /home/poduser/vault
#   /root/vault2      → /home/poduser/vault2
# This matters for stop_containers(): if it `cd`s into the wrong dir,
# `podman-compose down` finds no services and silently returns "stopped"
# while containers (and their open sqlite handles) keep running, which
# would corrupt a backup. Keep this convention.
readonly COMPOSE_DIR="/home/${USER_POD}/$(basename "$ROOT_VAULT_DIR")"

# ---- age (pinned binary, never auto-updated) ----------------------------
#
# To upgrade: run setup-age.sh <version>, then bump AGE_VERSION here.

readonly AGE_VERSION="v1.3.1"
readonly AGE_TOOLS_DIR="/srv/tools/age"
readonly AGE_BINARY="${AGE_TOOLS_DIR}/${AGE_VERSION}/age"
readonly AGE_BINARY_WIN="${AGE_TOOLS_DIR}/${AGE_VERSION}/age.exe"
readonly AGE_RECIPIENT_FILE="${ROOT_VAULT_DIR}/age-recipient.txt"

# ---- minisign (backup signing, see README §Minisign Key Pair Generation) ---------
#
# Pinned the same way age is pinned: setup-minisign.sh downloads Linux +
# Windows binaries into /srv/tools/minisign/<version>/ and this file
# references them by explicit version.
#
# To upgrade: run setup-minisign.sh <version>, then bump MINISIGN_VERSION
# here.
#
# Set SIGN_BACKUPS=false if you haven't set up minisign yet. backup.sh
# will then skip the signing step and leave the bundle unsigned.

readonly SIGN_BACKUPS=true

readonly MINISIGN_VERSION="0.12"
readonly MINISIGN_TOOLS_DIR="/srv/tools/minisign"
readonly MINISIGN_BINARY="${MINISIGN_TOOLS_DIR}/${MINISIGN_VERSION}/minisign"
readonly MINISIGN_BINARY_WIN="${MINISIGN_TOOLS_DIR}/${MINISIGN_VERSION}/minisign.exe"
readonly MINISIGN_KEY="${ROOT_VAULT_DIR}/minisign.key"
readonly MINISIGN_KEY_PASSPHRASE_FILE=""   # empty = no passphrase (unattended)
readonly MINISIGN_PUBKEY_FILE="${ROOT_VAULT_DIR}/minisign.pub"

# ---- deadman's switch (see ideas.md #2) --------------------------------
#
# Leave DEADMAN_URL empty to disable. When set, main.sh pings it after a
# successful backup so an external monitor can alert if the ping is late.

readonly DEADMAN_URL=""     # e.g. "https://hc-ping.com/<uuid>"

# ---- common file paths used across scripts -----------------------------

readonly DECRYPT_TXT="${ROOT_VAULT_DIR}/DECRYPT.txt"

# =========================================================================
# exit-code table
# =========================================================================
# Single source of truth for what each non-zero exit means. main.sh uses
# explain_exit_code() to narrate phase failures; sub-scripts use the same
# numeric codes in their fail() calls so nothing drifts.

declare -rA EXIT_CODE_DESC=(
    [0]="success"
    [1]="lock already held by another maintenance run"
    [2]="lib.sh missing or malformed"

    [10]="backup: age prerequisites missing (binary or recipient key)"
    [11]="backup: tar archive creation failed"
    [12]="backup: age encryption failed"
    [13]="backup: minisign prerequisites missing or signing failed"
    [14]="backup: final bundle creation failed"

    [20]="docker-update: cannot access compose dir / stop containers failed"
    [21]="docker-update: image pull failed after retries (non-fatal; logged only)"

    [30]="system-update: dpkg --configure -a failed"
    [31]="system-update: apt-get update failed"
    [32]="system-update: apt-get upgrade failed"
    [33]="system-update: apt-get dist-upgrade failed"

    [40]="reboot: blocked by safety check (containers running or apt/dpkg lock held)"

    [127]="required command missing from PATH"
)

# explain_exit_code RC, print "rc=N (description)" to stdout.
explain_exit_code() {
    local rc="$1"
    local desc="${EXIT_CODE_DESC[$rc]:-unknown exit code}"
    printf 'rc=%d (%s)' "$rc" "$desc"
}

# =========================================================================
# helpers
# =========================================================================

# log MESSAGE, append to the caller's phase log file ($PHASE_LOG), or
# stdout if that variable isn't set.
#
# Format depends on which log we're writing to:
#   - MAIN_LOG (orchestrator + reboot.sh interleave here):
#       [HH:MM:SS] [script.sh] message
#     The [script.sh] tag stays because two scripts share this file and
#     the reader needs to know which one emitted each line.
#   - phase logs (backup.sh / docker-update.sh / system-update.sh):
#       [HH:MM:SS] message
#     The filename already encodes the date (vault-backup-YYYY-MM-DD.log)
#     and only one script ever writes to it, so the date and tag are
#     dropped, easier to skim on a phone, same info density.
#
# A blank line is prepended to each entry so the resulting log is easy
# to skim, same visual rhythm the legacy single-file script had between
# operations. Tools that grep/parse the log are unaffected because empty
# lines don't match anything.
log() {
    local line
    if [[ "${PHASE_LOG:-}" == "$MAIN_LOG" ]]; then
        line="[$(date '+%H:%M:%S')] [${0##*/}] $*"
    else
        line="[$(date '+%H:%M:%S')] $*"
    fi
    if [[ -n "${PHASE_LOG:-}" ]]; then
        printf '\n%s\n' "$line" | tee -a "$PHASE_LOG"
    else
        printf '\n%s\n' "$line"
    fi
}

# fail MESSAGE [EXIT_CODE], log as FATAL and exit. If EXIT_CODE is in the
# table, the description is appended automatically.
fail() {
    local msg="$1" code="${2:-1}"
    log "FATAL: $msg, $(explain_exit_code "$code")"
    exit "$code"
}

# warn MESSAGE, log-only, does not exit.
warn() {
    log "WARN: $*"
}

# =========================================================================
# maintenance status events (JSON, for Wazuh -> Discord)
# =========================================================================

# emit_status PHASE STATUS RC [key=value ...]
# Append one JSON object (one line) to STATUS_LOG. STATUS is one of
# ok | degraded | fail. Extra key=value pairs become JSON string fields.
# event_type=vault_maint is the discriminator the manager rules key on;
# run_id (from $MAINT_RUN_ID, set by main.sh) ties one night's phase lines
# together so main.sh can roll them up into the `run` summary.
#
# printf-built (not jq) so EMITTING never depends on jq; values are
# escaped for backslash + double-quote. Package/image names don't contain
# those, but escape anyway so a weird value can't break the JSON.
emit_status() {
    local phase="$1" status="$2" rc="$3"; shift 3
    local ts json kv key val
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    json=$(printf '{"event_type":"vault_maint","run_id":"%s","ts":"%s","host":"%s","phase":"%s","status":"%s","rc":%d' \
        "${MAINT_RUN_ID:-}" "$ts" "$(hostname)" "$phase" "$status" "$rc")
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        val="${val//\\/\\\\}"   # escape backslash first
        val="${val//\"/\\\"}"   # then double-quote
        json+=$(printf ',"%s":"%s"' "$key" "$val")
    done
    json+='}'
    mkdir -p "$STATUS_LOG_DIR"
    printf '%s\n' "$json" >> "$STATUS_LOG"
}

# status_init PHASE, set up an EXIT trap that emits exactly one status
# line for this phase no matter how the script exits. After calling it a
# phase script may set PHASE_STATUS=degraded and append "key=value" detail
# to the PHASE_KV array; the trap emits them. If the script exits non-zero
# and PHASE_STATUS wasn't already set to fail, the trap marks it fail
# automatically (covers fail() and set -e aborts).
#
# NOTE: a script that ends in `exec` (reboot.sh) replaces its process, so
# the EXIT trap never fires on that path; such scripts emit explicitly
# before the exec instead.
status_init() {
    PHASE_NAME_FOR_STATUS="$1"
    PHASE_STATUS="ok"
    PHASE_KV=()
    trap '__status_on_exit' EXIT
}
__status_on_exit() {
    local rc=$?
    if (( rc != 0 )) && [[ "${PHASE_STATUS:-ok}" != "fail" ]]; then
        PHASE_STATUS="fail"
    fi
    emit_status "$PHASE_NAME_FOR_STATUS" "${PHASE_STATUS:-ok}" "$rc" "${PHASE_KV[@]}"
}

require_root() {
    [[ $EUID -eq 0 ]] || fail "must run as root" 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1" 127
}

# ensure_log_dirs, mkdir -p every log directory used by the pipeline.
# Safe to call from any script; idempotent.
ensure_log_dirs() {
    mkdir -p \
        "$MAIN_LOG_DIR"   \
        "$BACKUP_LOG_DIR" \
        "$DOCKER_LOG_DIR" \
        "$SYSTEM_LOG_DIR" \
        "$STATUS_LOG_DIR" \
        "$BACKUP_DIR"
}

# verify_age_prereqs, ensure the pinned age binary and recipient key are
# present before backup.sh starts doing real work. Sets AGE_RECIPIENT on
# success. Exits with code 10 otherwise.
verify_age_prereqs() {
    [[ -x "$AGE_BINARY" ]]     || fail "age binary missing or not executable: $AGE_BINARY (run setup-age.sh $AGE_VERSION)" 10
    [[ -f "$AGE_BINARY_WIN" ]] || fail "age.exe binary missing: $AGE_BINARY_WIN (run setup-age.sh $AGE_VERSION)" 10
    [[ -f "$AGE_RECIPIENT_FILE" ]] || fail "age recipient file missing: $AGE_RECIPIENT_FILE" 10

    AGE_RECIPIENT=$(grep -m1 '^age1' "$AGE_RECIPIENT_FILE" || true)
    [[ -n "$AGE_RECIPIENT" ]] || fail "no valid age public key (age1...) found in $AGE_RECIPIENT_FILE" 10
    log "age $AGE_VERSION ready, recipient=${AGE_RECIPIENT:0:20}..."
}

# verify_minisign_prereqs, only called if SIGN_BACKUPS=true. Exits with
# code 13 if anything is missing.
verify_minisign_prereqs() {
    [[ -x "$MINISIGN_BINARY" ]]     || fail "minisign binary missing or not executable: $MINISIGN_BINARY (run setup-minisign.sh $MINISIGN_VERSION)" 13
    [[ -f "$MINISIGN_BINARY_WIN" ]] || fail "minisign.exe binary missing: $MINISIGN_BINARY_WIN (run setup-minisign.sh $MINISIGN_VERSION)" 13
    [[ -f "$MINISIGN_KEY" ]]        || fail "minisign private key missing: $MINISIGN_KEY (see README §Minisign Key Pair Generation)" 13
    [[ -f "$MINISIGN_PUBKEY_FILE" ]] || fail "minisign public key missing: $MINISIGN_PUBKEY_FILE" 13

    local perms
    perms=$(stat -c '%a' "$MINISIGN_KEY" 2>/dev/null || echo "???")
    [[ "$perms" == "600" ]] || warn "minisign private key perms are $perms, should be 600 (chmod 600 $MINISIGN_KEY)"

    log "minisign $MINISIGN_VERSION ready, pubkey=$MINISIGN_PUBKEY_FILE"
}

# stop_containers, idempotent. Tears the compose stack down and waits
# until no container with a matching name is still running. Exits with
# code 20 on failure.
#
# Note: we use `podman-compose ps` everywhere to enumerate state, NOT
# bare `podman ps`. Reason: rootless podman's state lives under
# /run/user/<poduser-uid> via XDG_RUNTIME_DIR. `sudo -u poduser` does
# not inherit that env var from poduser's active session, so a bare
# `sudo -u poduser podman ps` launches with no runtime dir, sees no
# state, and returns empty, silently misreporting "nothing running".
# `podman-compose` bootstraps its own session context correctly, so
# `sudo -u poduser podman-compose ps` Just Works.
stop_containers() {
    cd "$COMPOSE_DIR" || fail "cannot access compose directory: $COMPOSE_DIR" 20

    # Fast path: skip the noisy `down` if nothing is running.
    local running_count
    running_count=$(sudo -u "$USER_POD" podman-compose ps 2>/dev/null | tail -n +2 | grep -c . || true)
    if (( running_count == 0 )); then
        log "no running containers, nothing to stop"
        return 0
    fi

    log "stopping containers via podman-compose"
    sudo -u "$USER_POD" podman-compose down 2>&1 | tee -a "${PHASE_LOG:-/dev/null}" || true

    # Verify by polling. `podman-compose down` is synchronous in the happy
    # path, but a hung container can drag it out, wait up to 30s for the
    # next `ps` to come up empty.
    local waited=0 max=30
    while :; do
        local still_up
        still_up=$(sudo -u "$USER_POD" podman-compose ps 2>/dev/null | tail -n +2 | grep -c . || true)
        (( still_up == 0 )) && { log "all containers stopped"; return 0; }
        sleep 1
        waited=$((waited + 1))
        (( waited >= max )) && fail "timeout: containers still running after ${max}s" 20
    done
}

# deadman_ping, optional, only fires if DEADMAN_URL is set. Failure is
# non-fatal: a monitoring-endpoint blip must not mark the backup as broken.
deadman_ping() {
    [[ -z "$DEADMAN_URL" ]] && return 0
    log "pinging deadman endpoint"
    if curl -fsS --retry 3 --max-time 10 "$DEADMAN_URL" >/dev/null 2>&1; then
        log "deadman ping OK"
    else
        warn "deadman ping failed, backup still ran, monitoring signal lost for this cycle"
    fi
}
