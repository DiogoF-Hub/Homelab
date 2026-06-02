# Future hardening ideas

Non-urgent hardening improvements discussed but not yet implemented. Each
entry: *what*, *why it matters*, *how to do it*, and *what it does NOT fix*.

Numbering is **stable**, completed ideas are stubbed in place rather than
deleted (other docs reference some of these by number; do not renumber).
Each stub records the gist + where the implementation landed, so the
historical context stays.

---

## 1. Sign backup bundles (not just encrypt), ✅ DONE

Implemented in `backup.sh`: every encrypted `*.tar.gz.age` is signed with
minisign (when `SIGN_BACKUPS=true`) and the `.minisig` ships inside the
final bundle. The minisign private key lives at `${MINISIGN_KEY}` on the
VM, the **public key is deliberately not bundled** (verifiers must use an
externally-stored trusted copy, bundling it would let an attacker who
swaps the bundle also swap the trust anchor). The manifest records
`minisign_pubkey=...` as a key-rotation lookup hint only.

Pinning of the minisign binary itself is handled by `setup-minisign.sh`
(parity with `setup-age.sh`), referenced from `lib.sh` via
`MINISIGN_VERSION` / `MINISIGN_BINARY`.

See: `scripts/root_scripts/backup.sh`,
`scripts/setups_scripts/setup-minisign.sh`,
README §Minisign Key Pair Generation, README §Backup and Redundancy.

---

## 2. Backup deadman's switch

> **Current plan:** keep `DEADMAN_URL`. (Update: Wazuh + Discord are now live
> for security events AND for the nightly maintenance run summary, see #7, so
> a failed/degraded run now pings #maintenance with an @. But the deadman's
> real job, catching the run that NEVER happens (VM dead, cron broken, disk
> full before the log), would need a "no `phase=run` event in 25h" silence
> rule, which is NOT built, the maintenance summary fires on a run, not on its
> absence. So `DEADMAN_URL` stays as the independent external net, and the
> user has decided to keep it permanently regardless: an external monitor that
> expects a ping at a fixed time still catches total-failure cases the on-box
> agent path structurally can't.)

### What

An external monitor that expects a ping from `main.sh` every 24h. If it
doesn't arrive within a grace window, the monitor alerts (email / Telegram /
webhook). No ping → something broke; ping → backup ran to completion.

### Why

Local logging catches backup failures that happen *during* `main.sh`. It
can't catch:

- VM powered off / crashed
- cron disabled or timer broken
- Script died before the logging section
- Disk full (can't even write the log)
- Someone disabled the job during troubleshooting and forgot to re-enable

Silent missed backups are the classic homelab failure mode, you discover the
gap at restore time, when it's already too late. A deadman's switch converts
"silent missing backup" into "email within 25 hours."

### How

1. Pick a provider:
   - **healthchecks.io**, free tier is generous (20 checks, email + webhook),
     SaaS. Simplest path.
   - **Self-hosted Healthchecks**, same software, Django app, runs on any
     small VM. Removes external-SaaS dependency. Worth the effort if the
     threat model rejects SaaS observability.

2. Create a new check, set expected schedule to daily with ~1h grace. Copy
   the ping URL (looks like `https://hc-ping.com/<uuid>` for SaaS or
   `https://checks.your-domain/ping/<uuid>` self-hosted).

3. Add to the end of the successful `main.sh` path (after reboot note is
   emitted but before actual reboot, or via a post-reboot systemd oneshot
   that fires only if the backup log exists and is recent):
   ```bash
   curl -fsS --retry 3 --max-time 10 \
        https://hc-ping.com/<uuid> >/dev/null \
        || echo "[WARN] deadman ping failed" >> "$BACKUP_LOG"
   ```
   The warning-on-failure is deliberate, if the ping itself fails, the
   backup still ran; you just lose the monitoring signal for one day. Don't
   fail the whole backup on a monitoring-endpoint blip.

4. Add the ping host to `proxy-home/vault_domains_allow_proxy.txt` so Squid doesn't block it:
   - SaaS: `hc-ping.com`
   - Self-hosted: your FQDN for the Healthchecks instance

5. Configure the notification channel (email, Telegram bot, etc.) on the
   provider side.

### Optional refinements

- **Separate signal for backup vs reboot.** Two checks: "backup completed"
  (pinged right after the age bundle is written) and "machine rebooted"
  (pinged on boot). Distinguishes "backup broke" from "VM never came back up."
- **Start/fail pings.** Healthchecks supports `/start` and `/fail` suffixes.
  Pinging `/start` at the top of `main.sh` and `/fail` on error gives runtime
  visibility, not just success/silence.

### What this does NOT fix

- The monitoring endpoint itself being wrong, e.g. you ping successfully but
  the encrypted archive is empty/corrupt. Verifying archive validity
  (decrypt-dry-run, signature check, minimum size threshold) belongs inside
  `main.sh` *before* the success ping.
- Network isolation from the monitoring endpoint: if Squid or DNS is broken
  on the VM, the ping fails for legitimate reasons even though the backup
  ran. Acceptable trade-off, false positives are recoverable ("I can reach
  the internet again"); false negatives (silent missed backup) aren't.

---

## 3. Scheduled host-level audits with Lynis

### What

Run [Lynis](https://cisofy.com/lynis/) on the VM on a schedule, archive the
report, and compare hardening-index deltas release-over-release. Not a
replacement for what's already in place, a second pair of eyes at the
OS/host layer (kernel, PAM, SSH, sysctl, filesystem perms, cron integrity,
package state) which this stack's own hardening doesn't touch.

### Why

The compose files harden the **containers**. Squid hardens **egress**.
Nothing in this repo audits the **host** itself. A misconfigured sshd
directive, a forgotten world-readable file under `/root`, a sysctl that
drifted from baseline, an apt source pointing somewhere unexpected, all
invisible to the container-level controls. Lynis catches the drift.

Already doing ad-hoc checks is fine; the win here is *repeatability*, same
checks every time, diffable output, so you notice when something you didn't
touch starts failing.

### How

1. Install from upstream (`apt` version lags badly):
   ```bash
   cd /opt
   git clone https://github.com/CISOfy/lynis.git
   cd lynis && git checkout <latest-tag>
   ```
   Pin the tag the same way `age` and (eventually) `minisign` are pinned,
   bump explicitly, don't auto-follow `main`.

2. Weekly systemd timer (or piggyback on `main.sh`) that runs:
   ```bash
   /opt/lynis/lynis audit system \
       --quick \
       --no-colors \
       --report-file "/var/log/lynis/report-$(date +%F).dat" \
       > "/var/log/lynis/output-$(date +%F).log"
   ```

3. Include `/var/log/lynis/` in the `main.sh` backup set so reports travel
   with the vault bundle, they're tiny and useful post-incident.

4. Allowlist entries (mirror any new one in BOTH `vault_domains_allow_dns.txt`
   and `proxy-home/vault_domains_allow_proxy.txt`, the usual lockstep
   convention):
   - **`lynis-latest-version.cisofy.com`**, REQUIRED regardless of install
     method. `lynis audit system` runs a version check against this host (a
     DNS TXT lookup for the latest release); without it Lynis logs an
     "update check failed" warning on every run. The DNS-side entry is the
     load-bearing one (it's a TXT lookup, so Pi-hole's `.*` deny-regex would
     otherwise block it); add the Squid one too to keep the pair in sync.
   - `packages.cisofy.com` / `github.com` (the latter already present), only
     needed if you switch to their APT repo; the git-clone install method
     needs no new entry for the binary itself.

5. First run produces a baseline hardening index (0–100). Subsequent runs
   should stay at-or-above that number; investigate any drop. Aim for the
   70s on a general-purpose VM; higher is possible but with diminishing
   returns.

### Optional refinements

- **CIS Debian benchmark plugin** (commercial, Lynis Enterprise) if you
  want formal benchmark mapping. The free version covers the practical
  overlap.
- **Diff last two reports in the log** and email only on regression,
  otherwise the weekly run is silent noise.

### What this does NOT fix

- Lynis audits *configuration*, not *behavior*. It will not notice a
  backdoored binary with correct perms, an authorized-but-malicious SSH
  key, or a compromised package mirror. Host IDS (AIDE, auditd rules)
  lives in a different bucket.
- No CVE scanning. Lynis flags unattended-upgrades being off, not which
  CVEs your installed versions are exposed to. Pair with
  `debsecan`/`unattended-upgrades` if that matters.

---

## 4. Encrypted DNS from the Vaultwarden VM, ✅ DONE (architecture has since evolved)

Originally implemented as `adguard/dnsproxy` running on the `proxy-home`
VM (`192.168.173.9:53`), forwarding every query DoH-encrypted to
Cloudflare Family. Logs lived at `/srv/dnsproxy-logs/queries.log`,
staged for Wazuh ingestion.

**Superseded.** The Vaultwarden VM now points its `/etc/resolv.conf` at
the homelab's existing **LAN Pi-hole** (`192.168.173.2`). Pi-hole
forwards upstream over DoH to Cloudflare Family via its own
`adguard/dnsproxy` sidecar (same encryption story), and the visibility
piece moved up the stack: Pi-hole's `pihole.log` is shipped via
wazuh-agent, with a custom decoder + rule chain on `wazuh-home` filtering
Vault-VM-srcip queries to a level-3 alert in the dashboard. The
dedicated dnsproxy compose was retired (`proxy-home/docker-compose.yml`
no longer exists); proxy-home is now Squid-only.

See: `wazuh-home/README.md` for the current architecture and apply
procedure; README §Outbound DNS via the LAN Pi-hole + Wazuh visibility.
The allowlist-anomaly follow-on (alert when a Vault VM lookup is for a
domain not on the Squid allowlist) is part of the broader Wazuh
rollout, see idea #7, Phase C, subsection "Allowlist-anomaly alert for
the Vault VM".

---

## 5. One-shot automated restore-verification script

### What

A single self-contained shell script (`verify-restore.sh` or similar) that
gets dropped into a folder alongside:

- A recent encrypted backup bundle (`vw-data-backup-YYYY-MM-DD.tar.gz.age`
  or the full wrapper tar).
- The age private key file.

Running the script takes the restore test end-to-end with zero manual
steps between decrypt and browser test:

1. Verify prerequisites (podman installed, ports free, files present).
2. Decrypt the bundle using the bundled age binary from the archive (or a
   pinned age on disk).
3. Extract into a scratch directory (e.g. `./restore-test/vw-data/`).
4. Launch a minimal Vaultwarden container pointed at that scratch dir,
   bound to `127.0.0.1:8080`.
5. Print `http://127.0.0.1:8080` and wait for the user to hit Enter
   after verifying in a browser.
6. On Enter (or on Ctrl-C, via a trap): stop the container, shred-delete
   the decrypted `vw-data/` and any temp files, optionally delete the
   bundle itself if a `--cleanup-bundle` flag is set.
7. Exit 0 on success, non-zero if any step failed.

### Why

The Phase 13 restore drill in `REBUILD.md` is correct but it's seven
manual steps, which means in practice it gets skipped or done wrong under
time pressure. A script turns "do a restore test" into "run the script",
a five-minute task you'll actually do quarterly instead of a half-hour
one you won't.

Second benefit: the script itself is documentation. Anyone opening it
sees the exact restore path, including which age binary, which container
image tag, which env vars Vaultwarden needs minimally to boot on an
imported data dir. If the restore path ever changes (schema migration,
data-dir reshape), the script fails loudly and forces the doc to stay
current.

### How

Core skeleton (not final, treat as a starting point):

```bash
#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?bundle path required}"
KEY="${2:?age key path required}"
SCRATCH="$(mktemp -d -p "$PWD" restore-test.XXXX)"
PORT="${PORT:-8080}"
CONTAINER="vw-restore-test-$$"

cleanup() {
  echo "[cleanup] stopping container + wiping scratch"
  podman stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # shred the decrypted vault copy before rm
  find "$SCRATCH" -type f -print0 | xargs -0 -r shred -u -n 1 || true
  rm -rf "$SCRATCH"
  echo "[cleanup] done"
}
trap cleanup EXIT INT TERM

echo "[1/4] decrypting $BUNDLE"
age -d -i "$KEY" "$BUNDLE" | tar -xzf - -C "$SCRATCH"

# Expected layout inside bundle: vw-data/
DATA_DIR="$SCRATCH/vw-data"
[[ -d "$DATA_DIR" ]] || { echo "no vw-data/ in bundle"; exit 2; }

echo "[2/4] launching minimal vaultwarden"
podman run -d --rm \
  --name "$CONTAINER" \
  -p "127.0.0.1:$PORT:8080" \
  -v "$DATA_DIR:/data:Z" \
  -e ROCKET_PORT=8080 \
  -e SIGNUPS_ALLOWED=false \
  vaultwarden/server:latest >/dev/null

echo "[3/4] waiting for /alive"
for i in {1..30}; do
  curl -fsS "http://127.0.0.1:$PORT/alive" >/dev/null && break
  sleep 1
done

echo "[4/4] READY, open http://127.0.0.1:$PORT and verify"
echo "       log in with your real master password"
echo "       press Enter when done to tear down"
read -r _
```

Refinements to add in the real version:

- Verify a minisign signature on the bundle **before** decrypt, done at
  signing-side per #1; the verify step needs implementing here. Pubkey
  must come from an externally-stored trusted source (NOT the bundle,
  the bundle deliberately omits it; see #1's notes).
- Use a throwaway network namespace so the test container can't reach
  anything else.
- `--cleanup-bundle` to shred the `.age` and key afterwards (only if
  running on a genuinely throwaway machine, default off).

### Split into two scripts: `decrypt.sh` + `start-test.sh`

The end-to-end script above is convenient for quarterly drills but
conflates two distinct jobs with different audiences:

- **`decrypt.sh`**, strictly decrypt + verify a bundle, output `vw-data/`
  to a target directory, stop. No container runtime needed. Audience:
  emergency recovery (operator, heir, trusted recovery contact).
- **`start-test.sh`**, take an already-decrypted `vw-data/` directory and
  spin up a minimal Vaultwarden against it for browser-level smoke
  testing, with the cleanup trap, scratch dir, and shred-on-exit. Needs
  Podman / Docker. Audience: operator running drills.

The two chain naturally:
```bash
./decrypt.sh --bundle X --pubkey Y --identity Z --out ./restored
./start-test.sh --data-dir ./restored/vw-data
```

This is worth the split for two reasons:

1. **Cross-platform reach.** `decrypt.sh` ports cleanly to a PowerShell
   sibling (`decrypt.ps1`) for the "the recovery person has a Windows
   laptop" case. `start-test.sh` doesn't need to port, by the time
   you're spinning up containers, you're on an operator-class machine.
   The current monolithic skeleton can't be split this way after the
   fact without rewriting most of it.
2. **Trust ladder for the binaries.** `decrypt.sh` should fetch fresh
   `age` + `minisign` binaries **from GitHub releases as priority 1**,
   pinned to the same versions used at backup time (read from the
   bundle's manifest). The bundled binaries drop to fallback-only. This
   eliminates the circular trust where an attacker who tampered with the
   bundle could also tamper with the binaries inside it that "verify"
   it. Tier ladder:
   - **Fresh from GitHub + `gh attestation verify`**, full chain
     (requires #8 for the verifier logic, but the same logic is reusable
     here).
   - **Fresh from GitHub, TLS-only**, independent network path, no
     circular trust.
   - **Bundled binaries**, fallback when offline. Prints a prominent
     reduced-trust warning.

   The script picks the highest tier silently; on fallback, prints a
   one-line warning. `--offline` flag forces tier 3 with no warning (for
   the genuine "no network" case). Architecture detection for the right
   GitHub artifact (`uname -m` on bash, `[Environment]::Is64BitOperatingSystem`
   on PowerShell).

This pairs tightly with #8: the same verifier logic that hardens
**setup-time** binary fetches in `setup-age.sh` / `setup-minisign.sh`
should be factored into a shared helper that **`decrypt.sh` reuses at
restore time**. Same trust anchor, two lifecycle moments.

`start-test.sh` keeps the current refinements list above (signature
verify, network namespace, cleanup-bundle flag), but signature verify
moves to `decrypt.sh`, since by the time `start-test.sh` runs the bundle
is already decrypted-and-verified upstream.

**Where the scripts live**: keep canonical copies in this repo under a
new `restore/` directory (version-controlled, reviewed via git). Bundle
a copy of `decrypt.sh` / `decrypt.ps1` into every backup as a fallback
for offline recovery, with `DECRYPT.txt` updated to say "prefer
downloading the latest version from <repo URL> over running the bundled
copy if you have network access", same circular-trust mitigation as
the binaries.

**Order of operations**: implement `decrypt.sh` (with the GitHub-fresh
binary tier) **before** the container-spin-up half. The decrypt path is
what an emergency recovery actually needs; the spin-up half is for
periodic drills and can land later.

### What this does NOT fix

- Still needs a human eyeball on the browser step. Automating the
  "entries are still there" check would mean scripting a Bitwarden-API
  login, which means storing a test account's credentials somewhere this
  script can reach, defeats the point. Keep the human in the loop for
  the "did I actually see my data" step.
- Only tests the bundle you point it at. Cron-driving the script over
  the latest bundle each week is possible but then you're running a
  Vaultwarden instance every week on sensitive data on whatever machine
  the script lives on, usually not what you want. Quarterly manual
  invocation on a throwaway machine is the sweet spot.
- Shredding on modern SSDs is advisory (FTL may have kept copies). Run
  on a machine whose disk you're willing to wipe if you're paranoid,
  e.g. a live USB or an ephemeral cloud VM that gets destroyed after.

---

## 6. Split `main.sh` into phase scripts + orchestrator, ✅ DONE

`main.sh` is now an orchestrator-only wrapper that flocks, then calls the
phase scripts in order: `backup.sh` → `docker-update.sh` →
`system-update.sh` → `reboot.sh`. Each phase is independently runnable
(`sudo /root/vault/backup.sh` works standalone) and sources a shared
`lib.sh` for readonly paths, helpers (`log` / `fail` / `warn` /
`require_root` / `stop_containers` / etc.), and the `EXIT_CODE_DESC`
table. Distinct exit codes per phase (10–14 backup, 20 docker, 30–33
system, 40 reboot) so `main.sh` can log without parsing stderr.

Failure policy implemented in `main.sh`:
- Backup failure → abort the whole run (no point updating a host whose
  data wasn't captured).
- Docker / system update failures → log and continue (retry tomorrow).
- Reboot is unconditional once safety gates pass (the Debian
  `/var/run/reboot-required` flag misses container-image-update
  reasons).

Restore is **deliberately not** part of the phase set, kept off the
production VM, manual and intentional. Idea #5 covers that path.

See: `scripts/root_scripts/{main,lib,backup,docker-update,system-update,reboot}.sh`,
README §Automation Scripts.

---

## 7. Wazuh SIEM rollout, structured logs, agent, alerts, Discord

> **Status, mostly DONE (the Discord payoff is live, including maintenance).**
> One `custom-discord` integrator on the manager pings per-source Discord
> channels for: ModSecurity attacks (rule 100303, band=high), DNS allowlist
> denials (100252, status=blocked-regex), Squid egress denials (TCP_DENIED),
> fail2ban bans (100401), AND the nightly maintenance run summary (100501 ok /
> 100502 degraded|fail → #maintenance). Decoders, rules, the integrator, and
> the `<integration>` blocks live in `wazuh-home/` (see its README). Rule-ID
> allocation: DNS 100250-100253, ModSecurity 100300-100303, fail2ban
> 100400-100401, maintenance 100500-100502.
>
> **Phase A is DONE:** `lib.sh` `emit_status` + `main.sh` `emit_run_summary`
> write a JSON status log (`/srv/logs/status/vault-maint-status.jsonl`, one
> line per phase + a `phase=run` rollup); the Vault VM agent tails it (a single
> stable file) and rules 100500-100502 fire the nightly report. Two non-obvious
> implementation notes: (1) the rules match a DERIVED `vw_sev` (info/warn)
> field, because Wazuh reserves `status` as a static field that `<field>`
> can't match (same trap as fail2ban's `action`); (2) the run summary is
> emitted BEFORE the reboot (not from main.sh's exit trap), so the agent ships
> it before the box goes down, an immediate `reboot -h now` otherwise races
> the shutdown and the summary is lost. A blocked-reboot escalation covers the
> "didn't reboot → Vaultwarden down" edge.
>
> **Still pending:** the **no-run-in-25h silence rule** that would actually let
> Wazuh replace `DEADMAN_URL` (#2) is NOT built, the maintenance summary fires
> on a run, not on its absence, so `DEADMAN_URL` stays (and the user wants it
> kept permanently regardless). Also: agent-down notifications (rule 504,
> investigated and parked, the nightly reboots show as clean stop/start
> 506/503 within the ~10-min disconnect threshold so they don't false-fire);
> shipping the Vault VM's own `vw-logs/` + `bw-logs/`; FIM. Phase B (manager +
> agents) is done.
>
> NOTE the implementation diverged from the Phase C sketch below: it uses
> Wazuh's `<integration>` integrator daemon (one `custom-discord.py` with a
> per-channel webhook map), NOT the Active Response approach sketched there.

The single "proper monitoring" idea. Everything in the current stack that
resembles "did something break? notify me", deadman pings, tail-and-grep
logs, manual `podman ps` checks, collapses into one SIEM. Big build, but
it subsumes several smaller ideas (#2 entirely, #3 largely).

### What

Stand up a dedicated Wazuh manager VM; install the Wazuh agent on the
Vaultwarden VM; feed it a structured JSON status log from `main.sh`;
write rules that alert on maintenance failures, CrowdSec bans, FIM hits,
and agent disconnects; route those alerts to Discord (and optionally
email/Telegram) via a Python Active Response script on the manager.

Three phases, each independently useful:

- **Phase A, structured JSON status log** (small, immediate value even
  without Wazuh).
- **Phase B, Wazuh manager + agent deployment** (the big infra build).
- **Phase C, alert rules + Active Response → Discord** (the payoff).

### Why

**Structured log (Phase A, standalone win):**
Human-readable logs are great for debugging; machines need structure.
Every external monitor that asks "did the backup run?" today has to tail
`vault-backup-*.log` and string-match "complete", or rely on deadman
presence/absence (#2). One JSON line with `phase` and `status` fields
collapses both into a primitive any tool consumes, tool changes, log
format doesn't.

**Wazuh (Phases B+C):** four things at once the current stack handles
partially or not at all:

1. **Maintenance-script alerting**, per-phase rules, different
   severities, webhook/email/Telegram natively. Replaces idea #2
   (deadman) entirely: Wazuh supports "alert if no event of signature X
   in N hours" rules, which is a better VM-alive check than a ping
   round-trip (the agent going silent IS the signal, no grace window).
2. **File Integrity Monitoring**, unauthorized changes to `/srv/vw-data`,
   compose files, `lib.sh`, `/etc/ssh/sshd_config.d/*`. Nothing else in
   this stack notices if an attacker modifies the backup script itself.
3. **Centralized log shipping**, `bw-logs/`, `vw-logs/`, journald,
   CrowdSec decisions into a single SIEM. One pane of glass instead of
   ssh-and-grep across three log directories.
4. **Off-box audit trail**, if the Vaultwarden VM is compromised, logs
   on the separate Wazuh manager survive. On-VM logs can be scrubbed by
   an attacker with root.

Overlaps with idea #3 (Lynis): Wazuh ships rootkit detection + CIS
benchmarking via its agent. Committing to Wazuh largely makes Lynis
redundant. Keep Lynis only if you want its specific report format.

### What this replaces (once live)

- **Idea #2 (deadman URL)**, entirely. Agent-status > external ping:
  detects "VM dead" immediately via missed keepalives instead of waiting
  for a grace window to expire.
- **Idea #3 (Lynis)**, largely. Wazuh agent covers rootkit + CIS scans.
- **Future "is Vaultwarden app container alive?" checks**, Wazuh rules
  on `podman ps` output or the container's own log.

Migration approach: run deadman AND Wazuh in parallel for ~30 days once
Wazuh rules are firing reliably, then retire `DEADMAN_URL` from
`lib.sh`. Redundancy during migration, not long-term.

---

### Phase A, Structured JSON status log, ✅ DONE

> Implemented. `lib.sh` has `emit_status PHASE STATUS RC [k=v ...]` (printf-built
> JSON, no jq dependency to emit) + a `status_init` EXIT-trap scaffold each
> phase script uses; `main.sh` has `emit_run_summary` that rolls the per-phase
> lines into a `phase=run` event (jq-aggregated). Output is a SINGLE file
> (`/srv/logs/status/vault-maint-status.jsonl`, as the sketch below shows),
> rotated host-side by logrotate. A dated-per-day variant was tried and
> reverted: the agent didn't pick up the brand-new daily file before the
> run's reboot, so the first cron night produced no Discord; one stable file
> keeps a persistent tail position. The run summary is emitted BEFORE the
> reboot phase (an exit-trap-after-reboot races the shutdown and the summary
> is lost). Wazuh ingests it (rules 100500-100502 → #maintenance). The
> shipped fields differ from the draft below: added `vw_sev` (the rule-match
> field, since `status` is a reserved Wazuh static field), `backup_size`,
> `images_updated`, `pull_failures`, `apt_upgraded`/`apt_count`; dropped
> `duration_s`.

Add to `lib.sh`:
```bash
readonly STATUS_LOG="${LOG_ROOT}/status/vault-maint-status.jsonl"
emit_status() {
    # emit_status PHASE STATUS RC [extra_key=value ...]
    local phase="$1" status="$2" rc="${3:-0}"; shift 3 || true
    # build JSON safely, jq if present, fallback printf
    ...
}
```
- Each phase script calls `emit_status` once at the end (success and
  failure). Replace `fail` with a variant that emits `status=fail` before
  exiting.
- `main.sh` emits a final `phase=run` line with the overall `STATUS`.
- Daily file, 30d retention (same pattern as other logs).
- Include `/srv/logs/status/` in the backup bundle, history survives VM
  loss.

Example output lines:
```json
{"ts":"2026-04-21T03:15:42Z","host":"vaultwarden","phase":"backup","status":"ok","rc":0,"duration_s":47,"bundle":"vaultwarden-backup-bundle-2026-04-21.tar.gz"}
{"ts":"2026-04-21T03:16:20Z","host":"vaultwarden","phase":"docker-update","status":"ok","rc":0,"images_updated":2}
{"ts":"2026-04-21T03:19:00Z","host":"vaultwarden","phase":"reboot","status":"skipped","rc":0,"reason":"no-reboot-required"}
{"ts":"2026-04-21T03:19:00Z","host":"vaultwarden","phase":"run","status":"ok","overall":"OK"}
```

Standalone-useful: even without Wazuh, this format is consumable by
healthchecks (#2), Uptime Kuma, a future dashboard, or a tiny cron
tail-and-mail script.

---

### Phase B, Wazuh manager + agent deployment

**Current state:** Wazuh agents are installed on the Vaultwarden VM, the
`proxy-home` VM, and the LAN Pi-hole VM, all enrolled with `wazuh-home`.
The Vault VM and proxy-home agents are at stock defaults. The **LAN
Pi-hole VM is the first agent with custom config**: a sidecar daemon
(`wazuh-home/sidecar/pihole/pihole-ftl-tail.py`) polls Pi-hole's FTL SQLite DB
and emits one structured JSON event per Vault VM DNS query to
`/var/log/vault-dns/events.log`; the agent tails that log; manager rules
100250 / 100251 / 100252 fire (archive base, resolved at level 3, blocked
at level 6). Snippets and the apply procedure live in the `wazuh-home/`
folder of this repo. The next slice (extending the sidecar to cross-check
each query against the Squid allowlist and emit a higher-level alert on
misses) is detailed in Phase C below.

Earlier intermediate state retired in favor of this: a text-log-decoder
approach with custom `pihole-dnsmasq-query` + `pihole-dnsmasq-blocked`
decoders and a four-rule chain (100190 / 100195 / 100200 / 100210). It
worked for Pi-hole's `gravity blocked` / `exactly denied` / `regex denied`
flavors but kept missing variants like `blocked upstream with NULL
address` and `<not set> X is 0.0.0.0`. The FTL DB has a normalized
`status` integer column that handles every block flavor uniformly, so
the text-log decoders + correlation rule were dropped.

The dnsproxy-on-proxy-home + `/srv/dnsproxy-logs/queries.log`
architecture below is **superseded**. The DNS visibility piece moved up
to the LAN Pi-hole + Wazuh decoder/rules described above. The
proxy-home agent has nothing application-specific to ship anymore. The
log-shipping for the Vaultwarden VM's own logs (`vw-logs/`, `bw-logs/`,
`/srv/logs/status/*.jsonl`) is still pending and is what's left of this
phase. The next slice (integrator script that cross-checks each query
against the Squid allowlist, only alerts on misses) is detailed in
Phase C below; sketch also in `wazuh-home/README.md` § "Planned next step".

What's left under Phase B:

- ~~Dedicated VM for the Wazuh manager.~~ ✅ Done.
- ~~Enrol agents with the manager.~~ ✅ Done (Vault VM, proxy-home,
  Pi-hole).
- ~~First custom decoder + rule chain.~~ ✅ Done (`wazuh-home/` folder,
  DNS visibility).
- Vaultwarden VM agent `<localfile>` sources for `/srv/logs/status/*.jsonl`
  (Phase A output, JSON-decoded automatically by Wazuh's built-in JSON
  decoder), `/srv/vw-logs/vaultwarden.log`, `/srv/bw-logs/access.log`,
  `/srv/bw-logs/error.log`, `/srv/bw-logs/modsec_audit.log`.
- Verify firewall posture for the manager link (1514/tcp events,
  1515/tcp enrollment) so Squid isn't in the path for internal-VLAN
  control traffic.
- Phase C alert rules + Discord Active Response (see below; allowlist-
  anomaly DNS alert is the headline DNS rule).

Below: the historical/aspirational dnsproxy-side wiring, kept for
reference. Skip directly to "What's left" above for the current plan.

**Historical/aspirational wiring (superseded by `wazuh-home/` folder for the DNS piece):**

- **proxy-home VM agent, `<localfile>` source** for dnsproxy queries:
  ```xml
  <localfile>
      <log_format>syslog</log_format>
      <location>/srv/dnsproxy-logs/queries.log</location>
  </localfile>
  ```
  (`syslog` log_format is the right choice for line-by-line tail,
  despite the name, it doesn't require actual syslog formatting.)
  Restart with `sudo systemctl restart wazuh-agent`.
- **Manager-side decoder for dnsproxy**, the log format is non-standard,
  so the manager won't extract fields without a custom decoder. Drop into
  `/var/ossec/etc/decoders/local_decoder.xml`:
  ```xml
  <decoder name="dnsproxy">
      <prematch>handler\.go:\d+:</prematch>
  </decoder>

  <decoder name="dnsproxy-query">
      <parent>dnsproxy</parent>
      <regex>(\d+\.\d+\.\d+\.\d+):\d+ -> (\S+) \((\S+)\)</regex>
      <order>srcip,dstdomain,query_type</order>
  </decoder>
  ```
  This unlocks rules over `srcip` / `dstdomain` / `query_type` in
  Phase C.
- Extend later (post-payoff): FIM on `/srv/vw-data`, `/etc/ssh`,
  `/root/vault/`, compose files; agentless collection of CrowdSec
  decisions; rootkit + CIS scans.

---

### Phase C, Alert rules + Active Response → Discord

**Rules (`local_rules.xml` on the manager, version-controlled in this
repo alongside compose files, rules-as-code):**

> Rule-ID ranges in use: DNS 100250-100253, ModSecurity 100300-100303,
> fail2ban 100400-100401, maintenance 100500-100502 (all in `wazuh-home/`).
> ✅ The maintenance rules below are now BUILT, at 100500-100502 in
> `wazuh-home/maintenance/manager-maint-rules.xml`, but the implementation differs from
> this sketch: they match a derived `vw_sev` (info/warn) field rather than
> `status` (Wazuh reserves `status` as a static field that `<field>` can't
> match), and the "no-run-in-25h" silence rule (the 100310 sketch below) is
> NOT built, so it does NOT yet replace `DEADMAN_URL`.

```xml
<rule id="100300" level="12">
  <decoded_as>json</decoded_as>
  <field name="phase">backup</field>
  <field name="status">fail</field>
  <description>Vaultwarden: backup phase FAILED</description>
  <group>vaultwarden_maint</group>
</rule>

<rule id="100301" level="7">
  <decoded_as>json</decoded_as>
  <field name="phase">docker-update</field>
  <field name="status">fail</field>
  <description>Vaultwarden: docker-update phase failed (non-fatal)</description>
  <group>vaultwarden_maint</group>
</rule>

<!-- deadman-equivalent: alert if no "phase=run" event in 25h -->
<rule id="100310" level="10" frequency="0" timeframe="90000">
  <decoded_as>json</decoded_as>
  <field name="phase">run</field>
  <description>Vaultwarden: no maintenance run completed in 25h</description>
  <group>vaultwarden_maint</group>
</rule>
```

Plus built-in rules: agent-disconnect (rule IDs in the 500 range,
exact numbers don't matter, they're labelled by the decoder), CrowdSec
decisions, FIM hits.

**DNS-driven rules** (over the `qtype` / `query` / `srcip` / `status` /
`blocked` fields the FTL-DB sidecar emits; see
`wazuh-home/sidecar/pihole/pihole-ftl-tail.py` for the field schema):

- High-volume queries from one client (DNS tunneling / DGA indicator).
- Queries to known-bad domains (threat-intel-driven blocklist match).
- NXDOMAIN-heavy patterns from one client (DGA indicator).
- Queries to domains blocked by Cloudflare Family, those return blocked
  responses; alerting tells you which client tried to reach what.

#### Allowlist-anomaly alert for the Vault VM, ✅ DONE (handled by Pi-hole regex enforcement, not Wazuh)

Originally drafted as a Wazuh-side feature: a dedicated rule (e.g.
100253, level 7) that fires only when a Vault VM lookup is for a
domain not on the Squid allowlist. The proposed mechanism evolved
across this idea: first a Wazuh integrator script invoked per
100200 alert, later a sidecar extension that adds an `allowed`
boolean to each event.

**Superseded by a simpler architectural choice:** Pi-hole's allowlist
scoped to the `vaultwarden-vm` group. The Vault VM is configured with
strict default-deny at the DNS layer:
- "Add allowlist" URL pointing at `vault_domains_allow_dns.txt`
  (Vaultwarden root) handles the bulk: bare-domain exact-match entries,
  re-fetched on each gravity update.
- A handful (~8) of apex+subdomain matches added by hand as Allow
  Regex via Domain Management. Apex matches can't go via the URL
  because Pi-hole 6's allowlist URL parser rejects ABP syntax
  (`||apex^`), so the file's APEX section lists the regex strings as
  source of truth, but the deployed copy lives in Pi-hole's UI.
- One `.*` Deny Regex scoped to the same group, added manually under
  Domain Management.

Effect: the Vault VM can only resolve domains in the allowlist; any
other lookup gets blocked at DNS time and FTL records it as
`status=blocked-regex` (status_code 4), which the FTL-DB sidecar
emits as a JSON event, which fires the existing rule 100252 at
level 6. So the "alert when the Vault VM tried to resolve something
unexpected" signal is now produced by Pi-hole + the existing rule
chain, with no extra Wazuh logic and no allowlist-comparison code in
the sidecar.

What's lost vs the originally-planned Wazuh-side comparator:
nothing operationally; what's gained: defense-in-depth (the Vault VM
is also blocked at DNS, not just alerted, even if Squid is misconfigured
or bypassed somehow).

What's NOT fixed by either approach:
- Doesn't catch lookups using non-Pi-hole resolvers. If something on
  the Vault VM resolves via `1.1.1.1` directly (hardcoded in a
  binary), Pi-hole never sees it. The Vault VM's egress firewall
  posture (only port 53 to `192.168.173.2` is allowed) is what
  actually prevents that.
- Doesn't distinguish reconnaissance from C2. Both look the same at
  the DNS layer: "domain not in our allowlist." Use it as a flag for
  investigation, not a verdict.

The remaining open work in this area is dual-allowlist sync, see the
follow-on subsection below.

#### Single source of truth for the Vault VM allowlist (cross-format generation)

Currently two manually-synced files in this repo encode the same
intent in different formats:
- `proxy-home/vault_domains_allow_proxy.txt`: Squid `dstdomain` syntax
  (one host per line; leading dot = apex + subdomains)
- `vault_domains_allow_dns.txt` (Vaultwarden root): two-section file.
  Bulk section: bare-domain exact-match entries, consumed by Pi-hole's
  "Add allowlist" URL feature. Apex section: `(^|\.)apex\.example$`
  regex strings (commented out so gravity skips them) listing the
  apex+subdomain entries that have to be added manually as Allow Regex
  in Pi-hole's Domain Management UI. Apex can't go via the URL because
  Pi-hole 6's allowlist URL parser rejects ABP syntax.

Both are appended to / edited by hand. Drift is the obvious failure
mode: add a destination to one file, forget the other, and either
HTTP egress (Squid) or DNS resolution (Pi-hole) silently fails for a
new endpoint.

End state: collapse to a **single** source of truth in the repo (a
yaml or txt with one entry per logical destination, plus optional
metadata like which subsystems each entry is needed by), with a
generator script that emits both `vault_domains_allow_proxy.txt` and
`vault_domains_allow_dns.txt` deterministically. Probably a small
Python script, ~50 lines, runnable by a CI job or pre-commit hook.

Sketch of the source-of-truth schema (yaml or txt, doesn't matter):

```
# one entry per line. exact host or `.apex.example` for apex+subs.
# free-form comment after `#` allowed; group lines by section header.
# the generator preserves comments and section headers in BOTH outputs.

deb.debian.org              # Debian package mirror
.lencr.org                  # Let's Encrypt OCSP / issuer chain
github.com                  # Pinned binary downloads
.bunkerity.com              # BunkerWeb assets + telemetry apex
```

Generator emits:
- Squid file: copy lines 1:1 (Squid uses the exact same syntax for
  dstdomain).
- Pi-hole file: bulk section gets bare-domain entries (Squid's
  `exact.host` -> `exact.host`); apex entries get expanded into the
  APEX section as PCRE2 regex (Squid's `.apex.example` ->
  `(^|\.)apex\.example$`).
- Optional bonus: --apply mode that pushes apex entries directly to
  Pi-hole's gravity / domainlist DB via SQLite or REST API, removing
  the manual UI step entirely. That's the "real" automation; the
  generator alone just keeps the two files in sync.

Both outputs preserve comments and section headers so the generated
files stay readable. Run on each repo edit (manual or pre-commit),
or once-a-day cron on `wazuh-home` to regenerate from a freshly
pulled repo and apply via Pi-hole's API.

Going further: the same generator could also push the Pi-hole regex
entries directly into the FTL gravity DB (atomic SQLite writes,
scoped to the `vaultwarden-vm` group), removing the manual
copy-paste step in Pi-hole's UI. Same script, extra `--apply` flag.

Why not yet: the manual two-file workflow is simple, the allowlist
changes maybe once a month, and getting the generator + apply path
right is more engineering than the current pain justifies. Revisit
when the file edit cadence picks up or when the next person editing
the repo gets bitten by drift.

**Active Response → Discord** (`/var/ossec/active-response/bin/discord-notify.py`
on the manager):

```python
import json, sys, os, urllib.request
WEBHOOK = os.environ["DISCORD_WEBHOOK_URL"]
alert = json.loads(sys.stdin.read())
rule = alert.get("rule", {})
body = {
    "username": "wazuh",
    "embeds": [{
        "title": f"[L{rule.get('level')}] {rule.get('description')}",
        "description": f"host: {alert.get('agent', {}).get('name')}\n"
                       f"rule: {rule.get('id')}\n"
                       f"```{alert.get('full_log','')[:1500]}```",
        "color": 0xE74C3C if rule.get("level", 0) >= 10 else 0xF1C40F,
    }],
}
req = urllib.request.Request(WEBHOOK, data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=5)
```

Webhook URL lives in a root-600 env file sourced by the AR wrapper,
**never** in version control.

**Wire rules → AR** in the manager's `ossec.conf`:
```xml
<command>
  <name>discord-notify</name>
  <executable>discord-notify.py</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

<active-response>
  <command>discord-notify</command>
  <location>server</location>
  <rules_group>vaultwarden_maint,crowdsec,syscheck,agent_disconnect</rules_group>
</active-response>
```

Adding a new alert source later = tag its rules with one of those
groups. No AR block edits needed.

**Egress allowlist:** `discord.com` / `discordapp.com` go on the **Wazuh
manager's** egress, not the Vaultwarden VM. The AR runs on the manager.

### Decide before committing

- **Threat model & effort:** optimizing for "get notified fast when a
  backup breaks" (→ stick with #2 deadman) or "unified security
  observability across the stack" (→ full Wazuh)? Deadman is an
  afternoon; full Wazuh is a weekend plus ongoing rule maintenance.
- **Infrastructure appetite:** Wazuh manager is another VM to patch,
  back up, firewall. If VM count is already tight, defer.
- **Implementation order:** do Phase A early regardless, it's a small
  refactor that's useful even without Wazuh. Phases B+C can wait until
  you're ready for the bigger build.
- **Notification channels:** Discord-only is fine for homelab scale.
  If "I cannot miss this alert" (e.g. travelling, Vaultwarden is the
  only password source), duplicate to SMS via a provider webhook.
- **Alert levels:** don't send every informational event to Discord,
  desensitization is real. Default threshold level ≥ 7 for the channel;
  success events don't need alerts at all, only failures + silence.

### What this does NOT fix

- **Phase A (JSON log) alone does not alert you.** It's a substrate.
  Something else has to watch it. Treat it as the *interface*, not the
  *alarm*.
- **Wazuh agent runs as root.** Long-lived root daemon on the VM, with
  an outbound persistent connection to the manager. Strictly more
  attack surface than one-shot `curl hc-ping.com`. Only worth it if
  using enough of Wazuh to justify the cost.
- **Wazuh manager is now a critical dependency.** Manager VM down = no
  alerts for anything, including the Vaultwarden VM being offline.
  Mitigation: a small external deadman (healthchecks.io) on the manager
  itself, one ping, one VM, simple.
- **Does not protect the log from a root-on-VM attacker.** An attacker
  with root can write fake `status=ok` lines or suppress `status=fail`
  ones during the window before the agent flushes. The on-disk JSON is
  not the source of truth; what the manager received is.
- **Discord / webhook outages.** Single notification channel = single
  point of failure. Duplicate to Telegram/email in the AR script if
  this matters.
- **Source-of-truth for rules lives on the manager.** If you version
  `local_rules.xml` in this repo (recommended), deploying rule changes
  means syncing to the manager + reloading, extra operational step.

---

## 8. Upstream signature verification in `setup-age.sh` / `setup-minisign.sh`

### What

Today both `setup-age.sh` and `setup-minisign.sh` download their tarballs
over TLS from GitHub, compute a local SHA-256, and stop there. TLS proves
"GitHub served me this byte-for-byte", it does *not* prove "the upstream
author intended to publish this artifact."

Extend each setup script to verify the release artifact against the
**upstream author's own signature** before installing it. Store the trusted
public key inline in `lib.sh` as a readonly constant; fail the install if
the signature does not match.

### Why

The realistic failure mode this catches: an attacker who compromises a
GitHub release (stolen maintainer token, CI pipeline takeover, account
hijack) and uploads a malicious replacement tarball. TLS is happy; the
upstream signature check fails.

Not theoretical, GitHub artifact replacement has happened to npm, PyPI,
and at least one Go project in the last few years. Pinning a version in
`lib.sh` and checksumming locally protects against *us* accidentally
fetching a newer-than-expected version, but does nothing against an
attacker who targets the exact version we're pinning.

### Tool-by-tool: what's available upstream

- **minisign (`jedisct1/minisign`)**, easiest case. Every release has a
  `.minisig` file next to the tarball. jedisct1's signing pubkey is
  well-known (published on his GitHub profile README, his site
  `00f.net`, cross-referenced on Keybase historically). The trust root
  is a single short string.

- **age (`FiloSottile/age`)**, a bit more involved. age releases are
  published with **SLSA provenance** (`.intoto.jsonl`) and signed
  checksums via **cosign / sigstore**, not minisign. Verification path
  is either:
    - `slsa-verifier verify-artifact --provenance ...` (extra tool, but
      purpose-built)
    - `cosign verify-blob --certificate-identity-regexp ...
      --certificate-oidc-issuer-regexp ...` against the keyless sigstore
      flow.
  Pins the trust root to sigstore's Fulcio CA + FiloSottile's GitHub
  Actions workflow identity, more moving parts than minisign, same
  guarantee.

### The chicken-and-egg problem (minisign specifically)

The very first install has no pinned `minisign` to verify with. Three
options; pick one and document the decision:

1. **Skip-on-first.** First install is TLS-only. From v2 onwards,
   `setup-minisign.sh <new-version>` uses the previous pinned `minisign`
   to verify the new tarball. Simple, but the foundational install is
   the unverified one.
2. **Apt-bootstrap.** `apt install minisign` once, use that to verify the
   first pinned download, then `apt remove minisign`. Adds one step to
   `REBUILD.md`; every install (including the first) is verified.
   **Recommended.**
3. **Second-implementation verify.** Use `signify` or a tiny Python
   Ed25519 script. Works, but adds a second tool to the supply chain
   we're trying to harden.

For age, no equivalent chicken-and-egg: `cosign` and `slsa-verifier` are
not what you're installing, they're pre-existing tools installed from
Debian or from their own upstreams. Pick whichever the operator already
trusts.

### How (minisign, concrete)

1. Add to `lib.sh`:
   ```bash
   # jedisct1's minisign signing pubkey, cross-checked against
   # https://github.com/jedisct1, https://www.00f.net, and the minisign
   # GitHub repo README on YYYY-MM-DD. Rotate this only after re-verifying
   # from at least two of those sources.
   readonly MINISIGN_UPSTREAM_PUBKEY="RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
   ```

2. In `setup-minisign.sh`, after downloading the tarball:
   ```bash
   # Resolve which minisign to verify with: prefer previously-pinned
   # version, fall back to apt-bootstrap, error out if neither.
   VERIFIER="$(command -v minisign || true)"
   # ... also check previous /srv/tools/minisign/*/minisign
   [[ -n "$VERIFIER" ]] || {
       echo "[ERROR] no minisign available for verification. Either:"
       echo "  - apt install minisign (bootstrap), then rerun this script"
       echo "  - pass --skip-verify to accept TLS-only (first-install only)"
       exit 1
   }
   curl -sfL -o "${TMP_DIR}/${LINUX_TARBALL}.minisig" \
       "${LINUX_URL}.minisig"
   "$VERIFIER" -V -P "$MINISIGN_UPSTREAM_PUBKEY" \
       -m "${TMP_DIR}/${LINUX_TARBALL}" \
       || { echo "[ERROR] upstream signature verification failed"; exit 1; }
   ```

3. Document the trust anchor in the README §Minisign Key Pair
   Generation section (or a sibling subsection), where the pubkey was
   sourced from, when, and how to re-verify it if future-you gets
   paranoid.

### How (age, concrete)

1. Add to `lib.sh`:
   ```bash
   # age releases are signed via sigstore (keyless, OIDC-bound to
   # FiloSottile's GitHub Actions workflow). Verification uses cosign
   # against these pinned identity patterns:
   readonly AGE_UPSTREAM_IDENTITY_REGEX="^https://github\.com/FiloSottile/age/"
   readonly AGE_UPSTREAM_OIDC_ISSUER="https://token.actions.githubusercontent.com"
   ```

2. In `setup-age.sh`, after downloading:
   ```bash
   require_cmd cosign    # or slsa-verifier, operator preference
   cosign verify-blob \
       --certificate-identity-regexp "$AGE_UPSTREAM_IDENTITY_REGEX" \
       --certificate-oidc-issuer "$AGE_UPSTREAM_OIDC_ISSUER" \
       --signature "${TMP_DIR}/${LINUX_TARBALL}.sig" \
       --certificate "${TMP_DIR}/${LINUX_TARBALL}.pem" \
       "${TMP_DIR}/${LINUX_TARBALL}" \
       || fail "age upstream signature verification failed"
   ```

3. Document in a sibling subsection of README §Age Key Pair Generation
   how to install `cosign` and what trust-on-first-install means for
   the sigstore root.

### Simpler alternative: `gh attestation verify`

GitHub now signs every release artifact via Sigstore's transparency log
("artifact attestations"), exposed through the official `gh` CLI. One
unified verifier for both repos, no need to install `cosign`,
`slsa-verifier`, or to bootstrap a minisign chain.

Both `FiloSottile/age` and `jedisct1/minisign` have to be opted in to
attestations on their release workflow for this to work, verify on
each version bump (the absence of an attestation is itself a flag).
At time of writing (2026-04-25): age opted in; minisign not yet
verified, needs a check before relying on this path for both.

```bash
# Inside both setup scripts, after downloading the artifact:
require_cmd gh
gh attestation verify "${TMP_DIR}/${LINUX_TARBALL}" \
    --owner FiloSottile \
    || fail "upstream attestation verification failed"
```

Pros vs the per-tool approaches above:
- **One verifier for everything**, including any other GitHub-released
  binaries you ever pull (Wazuh agent .deb, future tooling, etc.). The
  whole supply-chain story collapses to "do you trust GitHub
  attestations?"
- **No inline pubkey to maintain** in `lib.sh`, trust root is GitHub's
  Sigstore TUF store, updated automatically by the `gh` CLI.
- **No bootstrap problem** for minisign: `gh` is a binary you `apt
  install` once, no chicken-and-egg.

Cons:
- **Adds `gh` to the VM** as a dependency (`apt install gh` after adding
  GitHub's apt repo, and a repo-line/key step in `REBUILD.md`). Also
  means `packages.github.com` (or wherever you source `gh`) gets added
  to `proxy-home/vault_domains_allow_proxy.txt`.
- **Requires `gh auth status` to be authenticated** (or use
  `--bundle-from-oci` + a downloaded bundle file, possible but more
  verbose). Auth setup is a one-time step but it IS a step.
- **Trust delegated entirely to GitHub**, fine pragmatically, but the
  per-tool approaches above let you trust the upstream maintainers
  directly without GitHub in the trust path.

If pursued, this likely **replaces** the minisign-specific path entirely
and becomes a peer (or replacement) for the cosign-based age path.

### What this does NOT fix

- **Compromise of the upstream signing key itself.** If jedisct1's
  minisign key is stolen, or FiloSottile's GitHub Actions workflow is
  subverted, signatures verify fine on malicious artifacts. No pinning
  scheme escapes this.
- **Malicious upstream.** If the author is coerced or malicious, they
  sign the bad artifact themselves. Verification only proves "came from
  this author," not "the author is trustworthy."
- **Source-code-level compromise.** The signature attests to the release
  artifact, not to the source repo. A malicious commit that made it
  through review and got built into a signed release is still a signed,
  verified release.

### Decide before implementing

- **Which verification approach overall**: per-tool maintainer
  signatures (minisign+cosign) OR `gh attestation verify` (unified,
  GitHub-mediated). User leaning toward `gh attestation` (simpler,
  scales to other GitHub-released binaries we pull). Confirm minisign
  repo has attestations enabled before committing.
- **Which bootstrap path for minisign** (skip-on-first vs apt-bootstrap
  vs signify). Only relevant if NOT going with `gh attestation` (which
  has no bootstrap problem). Apt-bootstrap is cleanest; document the
  one-time step in `REBUILD.md`.
- **Whether to block on verification failure or just warn.** Block is
  correct for production. Warn-only is tempting during setup but
  silently defeats the point, recommend block-only and add a
  `--skip-verify` flag for the genuine first-install case.
- **Key rotation cadence for the inline pubkey / identity regex.**
  Infrequent in practice (jedisct1's key hasn't rotated; sigstore's
  identity model is stable). When it happens, treat the `lib.sh` edit
  as a high-scrutiny commit, it's modifying the trust root.
- **Order of operations with idea #1 (backup signing).** Upstream verify
  of `minisign` itself is a prerequisite for trusting the minisign
  binary that signs backups. Do this before relying heavily on #1.

---

## 9. Wazuh alert when the Vault VM resolves a domain not on the Squid allowlist, ✅ DONE (MERGED INTO #7)

Originally drafted as a standalone idea, but it's structurally a Wazuh
alert rule and belongs under the broader Wazuh rollout. Full write-up
moved to **idea #7, Phase C, subsection "Allowlist-anomaly alert for
the Vault VM"**, which is ✅ DONE: the Vault VM resolves through a Pi-hole
`vaultwarden-vm` group with a `.*` deny-regex + allowlist, so any
non-allowlisted lookup comes back `status=blocked-regex` and fires rule
100252 (→ #dns). The DNS layer actually BLOCKS the lookup, not just alerts,
so it's stronger than the Wazuh-only check first sketched here.

This stub is kept so cross-references to "idea #9" still resolve to a
forwarding pointer rather than a dead link. Don't expand back into a
parallel idea, edit it in place under #7.

---

## 10. Edge VPS as a CrowdSec bouncer, ✅ DONE

Implemented as a second bouncer (`VPS_FW_BOUNCER`) on the edge VPS,
running `crowdsec-firewall-bouncer-nftables` and polling the home
CrowdSec LAPI at `http://192.168.50.3:8080/` over the WG tunnel
every 10s. Same home CrowdSec engine keeps making decisions; the
VPS now drops banned IPs at the network edge before they cross
into home, in addition to BunkerWeb's in-stack plugin still 403-ing
inline at home (two enforcement layers, one engine).

Deployed with `set-only: false` (package default) so the bouncer
manages BOTH the IP set AND the drop chain in nftables, hooked
into `input` + `forward` at priority -10. Result: banned IPs are
dropped on EVERY destination port at the VPS, not just 80/443.
Includes SSH and WireGuard, so the rescue path is "SSH into the
home Vault VM from any LAN client, `cscli decisions delete --ip
<ip>`, wait 10s." Tested end-to-end: VPN IP ban resulted in TCP
SYN drops (not 403, the network-layer signature) and SSH from the
same IP also failed; unbanning via the home VM restored both
within seconds. CrowdSec's default whitelists parser also auto-
whitelists RFC1918 + WG private addresses, so the tunnel itself
can never get banned regardless of what scenarios fire.

Wiring:
- `BOUNCER_KEY_VPS_FW_BOUNCER` env var on the crowdsec service in
  the compose files reads `CROWDSEC_VPS_BOUNCER_KEY` from `.env`
  and auto-creates the bouncer on first home-side container start
  (idempotent across recreates). No manual `cscli bouncers add`.
- `crowdsec` service in `docker-compose.public-dns01.yml` (and
  `public-http01.yml`) publishes port 8080 on the host so the VPS
  can reach the LAPI; OPNsense is the load-bearing source-IP gate
  (`10.10.10.1 → 192.168.50.3:8080` is the only allowed path).
- VPS-side config template at
  `vps/crowdsec/crowdsec-firewall-bouncer.yaml`, deployed
  to `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` on
  the VPS with only `api_url` + `api_key` edited from defaults.

See: `vps/README.md` § "CrowdSec bouncer (block banned IPs at the
VPS edge)", main `README.md` § "Inbound from the edge VPS via
WireGuard" firewall table (row 3 = port 8080), `REBUILD.md` Phase
11 alternate + Phase 18 checklist, `CLAUDE.md` § Log pipeline
(bouncer section).

---

## 11. Kernel-level container confinement: seccomp + AppArmor profiles

Two kernel-level confinement layers were proposed for the three
containers (`vaultwarden`, `bunkerweb`, `crowdsec`), each stacking on
top of the existing compose hardening (`cap_drop: ALL` + minimal
`cap_add`, `no-new-privileges`, `tmpfs` for `/tmp` + `/var/run`,
`read_only: true` on Vaultwarden, resource limits, two-bridge network
segmentation) rather than replacing any of it.

The two layers turned out to have different fates, so this idea is
split into two clearly separate sub-parts:

- **11.1 Seccomp** (syscall allowlist): **live and actionable, do
  this.** Seccomp does not need root, a process can always restrict
  its own syscalls, so it works fine under rootless Podman.
- **11.2 AppArmor** (Mandatory Access Control over files / network /
  capabilities): **CUT.** AppArmor cannot be enforced under rootless
  Podman, and this stack is rootless. Kept below as the second
  sub-part for the record and the reasoning.

The two are independent: neither depends on the other, they just
happen to be applied through the same `security_opt` mechanism.
Seccomp is 11.1 because it is the one to actually do; AppArmor is 11.2
because it is cut. Read 11.1 as the live idea, 11.2 as a closed
investigation.

**Tangential cleanup surfaced during this analysis** (independent of
both sub-parts): BunkerWeb is granted `NET_BIND_SERVICE` but does not
need it, the internal ports 8080/8443 are above 1024 and host-side
80/443 binding is done by Podman's rootlessport via the
`net.ipv4.ip_unprivileged_port_start` sysctl, not by this capability.
Dropping it from BunkerWeb's `cap_add` is a standalone capability
tidy-up, neither seccomp nor AppArmor.

### 11.1 Seccomp profiles (live, actionable)

#### What

Add a custom **seccomp** profile (syscall allowlist) to each of the
three containers. Today all three run on Podman's default profile
(`/usr/share/containers/seccomp.json`), which blocks ~44
known-dangerous syscalls but allows the rest of the 300+ by design,
for broad compatibility. A custom profile inverts that: allow only the
syscalls the workload actually uses, deny everything else.

Target end state per container:

```yaml
security_opt:
  - no-new-privileges
  - seccomp=./seccomp/<container>.json   # custom allowlist, ~50-120 syscalls
```

Proposed repo layout:

```
Vaultwarden/
  seccomp/
    vaultwarden.json
    bunkerweb.json
    crowdsec.json
```

The `seccomp=` line has to be mirrored across all three compose
flavors (`public-dns01.yml`, `public-http01.yml`, `cf-tunnel.yml`),
the same way every other shared setting is kept in lockstep.

#### Why

If an attacker gets code execution inside any of these containers (a
Vaultwarden RCE, a WAF-bypass-plus-exec in BunkerWeb, a CrowdSec
vulnerability), their next move is almost always to abuse syscalls to
escalate or escape the container:

- `ptrace` to inspect or hijack other processes
- `mount` / `umount2` to reach host filesystems
- `kexec_load` to replace the running kernel
- `unshare` / `setns` to break out of namespaces
- `perf_event_open` for side-channel attacks
- `bpf` to load kernel programs

A tight seccomp profile removes those primitives at the syscall
boundary, regardless of what the attacker controls inside the
container. None of the three workloads need the full 300+ syscall
surface: Vaultwarden (Rust) likely needs ~50-80, CrowdSec (Go) a
moderate set, BunkerWeb (nginx + Lua + ModSecurity) the widest of the
three but still nowhere near all of them.

#### How

Use `oci-seccomp-bpf-hook`, a Podman-native OCI runtime hook that uses
eBPF to trace every syscall a running container makes and emits the
result as a JSON seccomp profile. crun in this environment is built
with `+EBPF`, which the hook requires (see README, "Container
runtime").

```bash
sudo apt install oci-seccomp-bpf-hook
```

Then trace each container (as `poduser`):

```bash
podman run \
  --annotation io.containers.trace-syscall=of:./seccomp/vaultwarden-trace.json \
  vaultwarden/server:latest
```

While the trace runs, every production code path must be exercised so
the profile captures everything the workload legitimately needs (the
per-container exercise checklists are below). Stop the container; the
JSON is a starting allowlist. Repeat for all three, place the results
in `seccomp/`, reference them via `security_opt: seccomp=...`. The
whole flow is short and self-contained: generate, apply, test,
iterate.

#### Per-container syscall notes

**Vaultwarden** (Rust, the most locked-down: `read_only: true`, zero
`cap_add`). Smallest syscall surface, the easiest tight profile.
Expected categories: file I/O (SQLite on `/data`), TCP (outbound
SMTP, inbound listen on 8080), signal handling, time, basic memory
management. Should NOT need `ptrace`, `mount`, `umount2`,
`kexec_load`, `unshare`, `setns`, `perf_event_open`, `bpf`,
`userfaultfd`, `syslog`. Trace exercise: login, admin panel, SMTP
send (device verification + registration), vault sync, the `/alive`
healthcheck, WebSocket notification path.

**BunkerWeb** (nginx + Lua + ModSecurity, multi-process, ACME
client). Widest syscall surface of the three: `clone` / `fork` for
workers, `mmap` for shared memory, `futex`, `epoll`, many socket
operations. Trace exercise: HTTP + HTTPS, Let's Encrypt DNS-01
renewal, CrowdSec LAPI calls, ModSecurity rule processing, rate
limiting, DNSBL lookups, custom-config loading on startup.

**CrowdSec** (Go, moderate syscall surface). Trace exercise: startup,
hub collection pull, bouncer registration, log parsing, decision-API
queries from the BunkerWeb + VPS bouncers, AND a forced hub update
(`cscli hub update && cscli hub upgrade`) so the trace captures the
`symlink` / `linkat` syscalls only used during hub operations.

#### Testing

Apply the generated profile, `podman-compose up -d`, exercise every
feature, watch `podman logs` for `SIGSYS` or unexpected exits, check
`journalctl -k | grep seccomp` for violations, add any missing
syscall to the JSON and restart, iterate until the full feature set
works under the custom profile.

#### Optional refinements

- **Regenerate profiles after significant image bumps.** A new
  `vaultwarden/server`, `bunkerweb-all-in-one`, or `crowdsec` image
  can introduce syscalls not in the existing profile. Fold a re-trace
  into the image-update runbook, or at minimum re-trace when a
  container starts crashing after an update.
- A scripted / CI re-trace so profile regeneration is not a manual
  chore each time `:latest` moves.

#### What this does NOT fix

- **Seccomp does not stop abuse of allowed syscalls.** If the workload
  legitimately needs `socket` + `connect`, an attacker with code
  execution can still open network connections; seccomp only removes
  syscalls the workload never uses.
- **Profiles drift against `:latest` images.** All three containers
  track `:latest`; each pull is a potential syscall-set change. A
  profile is a snapshot, not a guarantee, it needs ongoing
  maintenance.
- **The ModSecurity engine flip (DetectionOnly to On)** and the paired
  CrowdSec `crowdsecurity/modsecurity` scenario enable will change
  BunkerWeb's and CrowdSec's syscall surface. The seccomp profiles
  should be re-evaluated after that transition (tracked in
  `MONITORING.local.md`).
- **Does not prevent the initial compromise**, nor protect against a
  kernel 0-day reachable through an allowed syscall, nor against a
  malicious upstream `:latest` image push. Seccomp shrinks the
  post-compromise blast radius; it does not stop an attacker getting
  in.

### 11.2 AppArmor profiles, CUT (does not work under rootless Podman)

**Status: cut.** AppArmor was the other proposed kernel-level layer:
Mandatory Access Control over which files and directories a container
may read / write / execute, which network operations it may perform,
and which capabilities it may exercise, enforced regardless of
in-container privilege. It cannot be used on this stack.

#### Why it is cut

**If Podman runs rootless, AppArmor profiles do not apply. Full stop,
this is settled, not an open question.** This stack runs rootless (as
`poduser`, UID 1001), so the AppArmor sub-part is cut.

Applying an AppArmor profile to a container requires the profile to be
loaded into the kernel; loading needs `apparmor_parser`, which needs
root; a rootless engine running as an unprivileged user cannot do it.
So the Podman / containers stack reports AppArmor as unavailable for
any rootless engine and skips it entirely, `security_opt:
apparmor=<profile>` is ignored, never enforced. The host's own
AppArmor being healthy and loaded with profiles makes no difference:
the limitation is the rootless engine, not the host.

The one theoretical workaround (root pre-loads the profile, the
rootless container only references it by name) does not rescue it
either: Podman gates all AppArmor handling on an internal availability
flag that reads false for any rootless engine, regardless of what is
already loaded in the kernel.

**Rootful Podman was considered and rejected.** Running the three
containers rootful would make AppArmor available, but it would throw
away the rootless containment property that is a cornerstone of this
stack: under rootless a container escape lands the attacker as
`poduser` (UID 1001), an unprivileged user who still needs a separate
kernel privilege-escalation to reach root and who cannot touch the
root-owned backup crypto material in `/root/vault/`. Under rootful an
escape lands as host root immediately. That containment is worth far
more than the AppArmor hardening layer; trading it away would be a net
security loss. Rootless stays, AppArmor stays cut.

#### What it would have been (kept for the record)

If AppArmor were viable, the approach would have been: write profiles
from the `docker-default` base, load in complain mode (`aa-complain`,
logs violations without blocking), exercise the full feature set,
review violations (`aa-logprof`), switch to enforce mode
(`aa-enforce`). Per-container resource scopes that were sketched:

- **Vaultwarden**: write `/data/**`, `/logs/**`, `/tmp/**`; read
  `/etc/ssl/certs/**`, `/etc/resolv.conf`, `/etc/hosts`; network TCP
  only.
- **BunkerWeb**: the hardest to profile, the scheduler regenerates
  nginx config on every boot, so the profile would have to permit a
  broad dynamic write set (`/etc/nginx`, `/var/cache/nginx`, `/data`)
  or the container breaks on restart.
- **CrowdSec**: the profile would need to cover the read-only
  log-volume bind-mount sources (`/srv/bw-logs/**`, `/srv/vw-logs/**`).

Recorded only as a starting point if a future Podman version ever
supports referencing root-pre-loaded profiles from a rootless engine.
Until then 11.2 is closed: AppArmor adds nothing to this stack and is
not pursued.

---

## 12. Per-login notification via a Wazuh alert rule

### What

Get a notification on **every successful Vaultwarden login**, including
logins from already-known devices, by writing a custom Wazuh alert
rule that matches the successful-login log line and routes an alert
out (Discord, per #7 Phase C).

The gap: `REQUIRE_DEVICE_EMAIL=true` is set in the compose, but it only
emails on an **unrecognized** device. Once a device is verified, every
later login from it is silent. Vaultwarden has no built-in setting for
a passive "email me on every login" notification, so the visibility
has to come from the log + SIEM layer.

### Why

For a password manager, a successful login is a security-relevant
event even from a trusted device: it catches a stolen-but-still-paired
laptop, a session on a device you forgot was logged in, or an attacker
who has the master password and is using a device Vaultwarden already
trusts (so `REQUIRE_DEVICE_EMAIL` never fires). Failed logins are
already covered by CrowdSec's bruteforce + user-enum scenarios; this
idea closes the gap on the *successful* side.

Wazuh is the right tool: the agent is already enrolled on
`vaultwarden-home`, and alert rules + Discord Active Response are the
mechanism `ideas.md` #7 Phase C describes. This idea is a concrete,
narrow slice of that broader rollout.

### How

**The obstacle: `LOG_LEVEL`.** The Vaultwarden compose currently sets
`LOG_LEVEL: "error"`, which drops info-level events (a successful
login is info-level) before they ever reach
`/srv/vw-logs/vaultwarden.log`. With the line never written, there is
nothing for Wazuh to match.

**The fix: `LOG_LEVEL: "info"`.** Log levels are hierarchical, info
includes warn and error. So raising the level to info:

- keeps every failed-auth and error line CrowdSec needs for its
  bruteforce / user-enum scenarios (those are warn/error level and
  were already getting through);
- adds the info-level successful-login lines this idea needs;
- does not confuse CrowdSec: its parsers only match the specific
  failure patterns and simply ignore the extra info lines.

Steps:

1. Change `LOG_LEVEL` from `"error"` to `"info"` in the vaultwarden
   service env block, in all three compose flavors (kept in lockstep
   like every other shared setting). Restart the vaultwarden container.
2. Perform a test login, then inspect `/srv/vw-logs/vaultwarden.log`
   to capture the **exact** format of the successful-login line. The
   rule cannot be written accurately until this real line is in hand.
3. Confirm the Wazuh agent on the Vault VM has a `<localfile>` source
   for `/srv/vw-logs/vaultwarden.log`. This is part of #7 Phase B and
   is listed there as still pending; it is a hard prerequisite, with
   no localfile source the log never reaches the manager and the rule
   has nothing to match.
4. Write a custom manager rule (`local_rules.xml`) matching the
   confirmed success pattern, assign a sensible level, and tag it into
   the rule group that routes to the Discord Active Response script
   (#7 Phase C).
5. Verify end-to-end: a login produces a Wazuh alert and a Discord
   notification.

### Optional refinements

- **Enrich the alert** with the source IP, username, and device that
  Vaultwarden's success line carries, via a small custom Wazuh
  decoder, so the Discord message says "who, from where, on what"
  rather than just "a login happened".
- **Noise control** if per-login alerts get too chatty for a
  multi-user vault: scope the rule to fire only on a login from a new
  source /24, or only for specific accounts. For 5-6 users a plain
  per-login alert is probably fine as-is.

### What this does NOT fix

- **`LOG_LEVEL: "info"` raises log volume substantially.** Every
  successful login plus other info chatter now lands in
  `vaultwarden.log`. Watch the effect on: the log file size (the
  `/etc/logrotate.d/vaultwarden` config is daily / keep 3 /
  copytruncate, should cope), CrowdSec's parse volume (negligible),
  and the Wazuh agent's shipping volume to the manager (more events,
  more indexer growth). Re-check disk + indexer after the flip.
- **The on-VM log is not tamper-proof.** An attacker with root on the
  Vault VM can suppress the success line before the agent ships it;
  what the manager received is the source of truth, not the on-disk
  file (same caveat as #7). This alerts on logins under normal
  conditions, it is not an integrity guarantee.
- **Successful logins only.** Failed-login alerting stays CrowdSec's
  job via the existing scenarios; this idea does not touch that path.
- **Cannot be fully spec'd until step 2 is done.** The exact rule
  regex depends on the real log-line format, which only appears once
  `LOG_LEVEL: "info"` is live and a test login has been captured.

