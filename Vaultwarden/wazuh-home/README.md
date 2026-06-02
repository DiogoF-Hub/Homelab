# Wazuh visibility + alerting for the Vaultwarden stack

This folder holds the Wazuh-side configuration for the Vaultwarden stack: structured log pipelines into the Wazuh manager (`wazuh-home`), plus per-source Discord notifications via one integrator. It started as DNS-only visibility and has grown to five sources.

## Pipelines at a glance

| Source | Surfaces | Manager rules | Discord (channel / when) |
|--------|----------|---------------|--------------------------|
| **DNS** (Pi-hole FTL sidecar) | every Vault VM DNS query; allowlist denials | 100250-100253 | #dns, `status=blocked-regex` |
| **ModSecurity** (BunkerWeb WAF) | CRS matches, tiered by anomaly score | 100300-100303 | #modsec, `band=high` (score ≥ 30) |
| **fail2ban** (all hosts) | SSH brute-force bans | 100400-100401 | #fail2ban, every ban |
| **Squid** (proxy-home) | egress-allowlist denials | built-in `squid` group | #squid, `action=TCP_DENIED` |
| **maintenance** (Vault VM `main.sh`) | nightly run summary (backup / docker / apt / reboot) | 100500-100502 | #maintenance, every run (green OK; @ on degraded/fail) |

One integrator, `integrations/custom-discord.py`, fans these out to per-channel Discord webhooks (the data-field filter lives in the script + a `discord-webhooks.json` side-file on the manager holds the real URLs; `integrations/manager-discord-integration.xml` has the `<integration>` blocks that decide which alerts reach it). Rule-ID map: DNS 100250-100253, ModSecurity 100300-100303, fail2ban 100400-100401, maintenance 100500-100502 (the retired text-log DNS pipeline used 100190-100210; keep new pipelines clear of those).

Squid has no files in this folder beyond its `<integration>` block: the Wazuh agent installer auto-discovers `/var/log/squid/access.log` on proxy-home, and the squid decoder/rules are built into Wazuh, so there's nothing custom to deploy for it.

The **DNS pipeline is documented in full below** (it's the most involved, with a sidecar daemon). ModSecurity, fail2ban, maintenance, and Discord each get a short section further down pointing at their snippet files, whose header comments carry the detailed rationale.

## Folder layout

Snippets are grouped one folder per pipeline, plus a shared `manager/` +
`integrations/`, and the per-host `sidecar/` daemons:

```
wazuh-home/
├── dns/           manager-rules.xml + pihole-agent.localfile.xml
├── modsec/        manager-modsec-rules.xml + vault-modsec-agent.localfile.xml
├── fail2ban/      manager-fail2ban-decoder.xml + manager-fail2ban-rules.xml + fail2ban-agent.localfile.xml
├── maintenance/   manager-maint-rules.xml + vault-maint-agent.localfile.xml
├── manager/       manager-global.snippet.xml          (logall_json; manager-wide, not pipeline-specific)
├── integrations/  custom-discord.py + manager-discord-integration.xml
└── sidecar/
    ├── pihole/    pihole-ftl-tail.py + .service        (installs on the LAN Pi-hole VM)
    └── vault/     modsec-tail.py + .service            (installs on the Vault VM)
```

Convention: `manager-*.xml` append to the **manager**'s `local_rules.xml` /
`local_decoder.xml` / `ossec.conf`; `*-agent.localfile.xml` append to the
relevant **agent**'s `ossec.conf`; `sidecar/<host>/` files install under
`/usr/local/sbin/` + `/etc/systemd/system/` on that host. None of the XML
files are drop-in replacements, they're snippets to merge into stock Wazuh
config.

---

## DNS visibility (Pi-hole FTL)

This routes the VM's DNS through the homelab's existing LAN Pi-hole, tails Pi-hole's FTL SQLite database with a small sidecar daemon, and ships structured per-query events into Wazuh.

It is the successor to two earlier iterations:

1. The original "dnsproxy on the proxy-home VM" setup, retired when DNS visibility moved up the stack into Wazuh.
2. The first "Wazuh on Pi-hole's text log" iteration, retired because Pi-hole's dnsmasq text log emits four-plus different syntactic patterns for "this query was blocked" depending on the source (gravity adlist, manual exact-deny, regex, blocked-upstream-NULL, externally-blocked NXDOMAIN, ...). Building decoder regex that catches them all and stays correct across Pi-hole versions was whack-a-mole. The current FTL-DB approach reads Pi-hole's normalized `status` integer column instead.

## Why this exists

Two things the Vault VM gets out of this:

1. **Visibility**: every DNS query the VM makes (Let's Encrypt endpoints, Cloudflare tunnel, CrowdSec hub, apt mirrors, the Vaultwarden domain itself, Wazuh feeds) shows up as a Wazuh alert in the dashboard, scoped to the Vault VM's source IP, with full per-query metadata (qtype, query, status, blocked-or-not). If the host gets compromised and starts phoning home, the resolution attempt is captured before egress even tries.
2. **DoH-encrypted upstream + Family-DNS filtering**, inherited from Pi-hole's existing `adguard/dnsproxy` upstream. Same upstream encryption story as the old dedicated-DoH-gateway setup, no plaintext-on-LAN sniffability.

Unexpected-domain alerting is already handled: the Vault VM resolves through a Pi-hole `vaultwarden-vm` group with a `.*` deny-regex + allowlist, so any non-allowlisted lookup comes back `status=blocked-regex`, fires rule 100252, and pings #dns. That subsumes the "allowlist-anomaly" feature originally sketched for a Wazuh integrator; see `Vaultwarden/ideas.md` idea #7 Phase C.

## Architecture

```
Vaultwarden VM (192.168.50.3, VLAN-DMZ)
  /etc/resolv.conf -> 192.168.173.2
              │
              │  UDP/53 (DMZ -> LAN; OPNsense pass rule)
              ▼
LAN Pi-hole VM (192.168.173.2)
  ├─ pihole-FTL (dnsmasq)
  │     writes /etc/pihole/pihole-FTL.db (SQLite, host bind mount via PiHole/docker-compose.yml)
  │
  ├─ adguard/dnsproxy (sidecar, DoH upstream to Cloudflare Family)
  │
  ├─ pihole-ftl-tail.py (this folder's sidecar daemon, systemd-managed)
  │     polls FTL DB every 10s, filters to Vault VM client
  │     emits one JSON line per query to /var/log/vault-dns/events.log
  │     fields: srcip, qtype, query, status (label), status_code (int), blocked (bool), forward
  │     /etc/logrotate.d/vault-dns rotates daily, keeps 14 compressed
  │
  └─ wazuh-agent
        tails /var/log/vault-dns/events.log (structured JSON, per-query)
              │
              │  encrypted to manager
              ▼
wazuh-home (manager)
  ├─ built-in JSON decoder auto-extracts every key from the JSON lines into data.*
  ├─ rule 100250 level 0  (every Vault DNS event, archived; discriminated by event_type=vault_dns)
  ├─ rule 100251 level 3  (resolved query: forwarded / cached / etc)
  ├─ rule 100252 level 6  (Pi-hole's allowlist policy denied: gravity, regex, exact deny, CNAME variants)
  └─ rule 100253 level 4  (upstream returned non-answer: NULL / NXDOMAIN / NODATA, e.g. Cloudflare Family filtering or domain has no A record)
```

## Files in this folder

| File | Where it goes | What it does |
|------|---------------|--------------|
| `sidecar/pihole/pihole-ftl-tail.py` | Install at **Pi-hole VM** `/usr/local/sbin/pihole-ftl-tail.py` | The daemon. Reads Pi-hole's FTL DB, emits structured JSON events. ~360 lines, stdlib only |
| `sidecar/pihole/pihole-ftl-tail.service` | Install at **Pi-hole VM** `/etc/systemd/system/pihole-ftl-tail.service` | Systemd unit running the daemon as root with hardening (`ProtectSystem`, `RestrictAddressFamilies=AF_UNIX`, etc.) |
| `dns/pihole-agent.localfile.xml` | Append to a `<ossec_config>` block in **Pi-hole VM** `/var/ossec/etc/ossec.conf` | Tells the Wazuh agent to tail the sidecar's `/var/log/vault-dns/events.log` (JSON format) |
| `manager/manager-global.snippet.xml` | One-line addition inside the `<global>` block in **wazuh-home** `/var/ossec/etc/ossec.conf` | Enables `logall_json` so level-0 events (rule 100250 base) land in `archives.json` and are searchable. Pair with `archives.enabled: true` in `/etc/filebeat/filebeat.yml` to also expose them as `wazuh-archives-4.x-*` in the dashboard (see deploy step 5) |
| `dns/manager-rules.xml` | Append inside **wazuh-home** `/var/ossec/etc/rules/local_rules.xml` | Four-rule chain: 100250 (archive base) + 100251 (resolved) + 100252 (Pi-hole policy block) + 100253 (upstream no-answer) |

These are reference snippets, not deployable files. The actual files on each VM (`ossec.conf`, `local_rules.xml`) carry stock Wazuh content that we don't replace; we only append our additions. Exception: the sidecar script + systemd unit get installed verbatim under `/usr/local/sbin/` and `/etc/systemd/system/` respectively.

The Pi-hole regex allowlist that pairs with this stack lives at [`Vaultwarden/vault_domains_allow_dns.txt`](../vault_domains_allow_dns.txt), one level up. It's not in this folder because it isn't really Wazuh config; Wazuh just observes the result. See `Vaultwarden/README.md` § "Pi-hole groups + DNS-layer allowlist for the Vault VM" for the deploy procedure.

There is **no** `manager-decoder.xml` in this folder. The previous text-log pipeline used a custom dnsmasq decoder; the current FTL-DB pipeline uses Wazuh's built-in JSON decoder, which auto-extracts every JSON key into `data.*` fields. No custom decoder needed.

## Apply order

### 1. Confirm the Pi-hole compose has the FTL DB bind mount

The sidecar reads the DB on the **host** at `/home/pi/pihole/data/etc-pihole/pihole-FTL.db`, which is the bind-mount target of the container's `/etc/pihole`. If your compose uses a different path, update `FTL_DB` near the top of `pihole-ftl-tail.py`.

Quick check:

```bash
ls -la /home/pi/pihole/data/etc-pihole/pihole-FTL.db
sudo sqlite3 -readonly /home/pi/pihole/data/etc-pihole/pihole-FTL.db \
  "SELECT count(*) FROM queries WHERE timestamp > strftime('%s','now','-1 hour')"
```

If the count returns a positive number, the DB is reachable and writing.

### 2. Install the sidecar on the Pi-hole VM

```bash
# create the log + state dirs (the script creates them too, but doing
# it explicitly lets logrotate's `create` directive find correct
# parents on day one)
sudo mkdir -p /var/log/vault-dns /var/lib/pihole-ftl-tail
sudo chown root:root /var/log/vault-dns /var/lib/pihole-ftl-tail
sudo chmod 0750      /var/log/vault-dns /var/lib/pihole-ftl-tail

# from the repo working copy on the Pi-hole VM (or scp the two files
# over)
sudo install -m 0755 sidecar/pihole/pihole-ftl-tail.py     /usr/local/sbin/pihole-ftl-tail.py
sudo install -m 0644 sidecar/pihole/pihole-ftl-tail.service /etc/systemd/system/pihole-ftl-tail.service

sudo systemctl daemon-reload
sudo systemctl enable --now pihole-ftl-tail

# verify the daemon is running and emitting
sudo systemctl status pihole-ftl-tail
sudo journalctl -u pihole-ftl-tail -n 20
sudo tail -f /var/log/vault-dns/events.log
```

Set up logrotate (host-side config, NOT shipped in the repo, see Vaultwarden README §Log Rotation for the canonical config text):

```bash
sudo apt install -y logrotate    # if not already installed
sudo nano /etc/logrotate.d/vault-dns
# paste the config from Vaultwarden/README.md §Log Rotation → LAN Pi-hole VM

# verify it parses cleanly (dry-run, no actual rotation)
sudo logrotate -d /etc/logrotate.d/vault-dns
```

The daily run is invoked automatically by Debian's `/etc/cron.daily/logrotate` or systemd's `logrotate.timer`; nothing extra to schedule.

If you do an `nslookup github.com` from the Vault VM, a JSON line should appear in `/var/log/vault-dns/events.log` within 10 seconds. Each line looks like:

```json
{"event_type":"vault_dns","ts":"2026-05-01T20:27:04+02:00","pi_id":1234567,"srcip":"192.168.50.3","qtype":"A","qtype_code":1,"query":"github.com","status":"forwarded","status_code":2,"blocked":false,"forward":"127.0.0.1#5335"}
```

### 3. Wire the Wazuh agent on the Pi-hole VM

Append the `<ossec_config>` block from `dns/pihole-agent.localfile.xml` to `/var/ossec/etc/ossec.conf` (the agent merges multiple `<ossec_config>` blocks at the top level). Restart:

```bash
sudo systemctl restart wazuh-agent
sudo grep "vault-dns-events" /var/ossec/logs/ossec.log | tail
# expect: Analyzing file: '/var/log/vault-dns/events.log'
```

### 4. Apply the manager-side rules

On `wazuh-home`:

```bash
# enable archive logging on the manager (only if you haven't already; check first)
sudo grep logall_json /var/ossec/etc/ossec.conf
# if missing, add <logall_json>yes</logall_json> inside <global>; see manager/manager-global.snippet.xml

# install the rules
sudo nano /var/ossec/etc/rules/local_rules.xml
# append the contents of dns/manager-rules.xml (the <group name="dns,pihole,vaultwarden"> block)

# validate before reloading; analysisd -t parses without starting the daemon
sudo /var/ossec/bin/wazuh-analysisd -t

# if clean, restart the manager
sudo systemctl restart wazuh-manager
```

### 5. Enable archives ingestion in filebeat (optional but recommended)

The `<logall_json>yes</logall_json>` setting from step 4 only writes to `/var/ossec/logs/archives/archives.json` on disk. To also see archives in the Wazuh dashboard's `wazuh-archives-4.x-*` index (so you can pivot to rule 100250 events without `grep`-ing the file by hand), filebeat's wazuh archives module needs enabling:

```bash
sudo nano /etc/filebeat/filebeat.yml
```

Find the `filebeat.modules:` section and flip `archives.enabled` from `false` to `true`:

```yaml
filebeat.modules:
  - module: wazuh
    alerts:
      enabled: true
    archives:
      enabled: true     # was false
```

```bash
sudo systemctl restart filebeat
```

Within ~10s the `wazuh-archives-4.x-*` index pattern appears in the dashboard's data-source picker. Filter `rule.id : "100250"` to find catch-all events.

**Trade-off**: enabling this roughly doubles the indexer's write rate (every decoded event now also lands in `wazuh-archives-*`, on top of `wazuh-alerts-*`). Worth it for the visibility on rule 100250 plus general manager-side observability (agent disconnect events, FIM scans, internal Wazuh chatter that doesn't normally trip a rule). Plan to set up ILM or manual index pruning so the indexer doesn't fill up over time.

If you'd rather skip this step, the alternative is to bump rule 100250's level from 0 to ~5 in `dns/manager-rules.xml`. Then catch-all events fire alerts directly into `wazuh-alerts-*`, no archives ingestion needed. Less infrastructure but only DNS-event visibility, not the broader Wazuh stream.

### 6. Network plumbing

- **OPNsense rule**: pass `192.168.50.0/24 -> 192.168.173.2` on TCP+UDP port 53. Without this the Vault VM's queries never reach Pi-hole and the alerts will be empty.
- **Vault VM `/etc/resolv.conf`**: `nameserver 192.168.173.2`. Make it survive reboots via whatever manages networking on the VM (`/etc/network/interfaces`, netplan, systemd-resolved drop-in).

### 7. Verify end-to-end

```bash
# from the Vault VM
nslookup github.com 192.168.173.2     # resolves normally -> rule 100251
nslookup ads.google.com 192.168.173.2 # blocked by Pi-hole exact-deny -> rule 100252
nslookup rivestream.xyz 192.168.173.2 # blocked by upstream (Cloudflare Family) -> rule 100253

# on wazuh-home
sudo tail -f /var/ossec/logs/alerts/alerts.json \
  | jq -r 'select(.rule.id=="100251" or .rule.id=="100252" or .rule.id=="100253") | "\(.timestamp) [\(.rule.id)] \(.data.qtype) \(.data.query) \(.data.status)"'
```

Within a couple of seconds you should see one alert per qtype (most domains query both A and AAAA in parallel) with the right rule.id depending on whether the query resolved or was blocked.

If you enabled archives ingestion in step 5, you can also pivot in the Wazuh dashboard:

- `wazuh-alerts-4.x-*` index, filter `rule.id : "100251" or rule.id : "100252" or rule.id : "100253"`: per-query alerts.
- `wazuh-archives-4.x-*` index, filter `rule.id : "100250"`: catch-all events (uncategorized status codes, malformed events, etc.). Should normally be empty; non-empty = something needs investigating.

## Migration from the previous text-log pipeline

If you previously deployed the text-log decoder + rule chain (`pihole-dnsmasq-query`, `pihole-dnsmasq-blocked`, rules 100190 / 100195 / 100200 / 100210), retire them after verifying the new pipeline works.

**Steps to clean up:**

On the **Pi-hole VM**, edit `/var/ossec/etc/ossec.conf` and remove any old `<localfile>` blocks for `/var/log/pihole/pihole.log` and `/var/log/pihole/FTL.log` (both are gone now since the host bind mount of `/var/log/pihole` was dropped from `PiHole/docker-compose.yml` along with the text-log pipeline). Restart the agent.

On **wazuh-home**, edit `/var/ossec/etc/decoders/local_decoder.xml` and remove the two custom decoders:

```
<decoder name="pihole-dnsmasq-query">...
<decoder name="pihole-dnsmasq-blocked">...
```

Then edit `/var/ossec/etc/rules/local_rules.xml` and remove the four old rules:

```
<rule id="100190" ...>  (DNS query base, level 0)
<rule id="100195" ...>  (gravity blocked base, level 0)
<rule id="100200" ...>  (Vault VM query, level 3)   <-- repurposed below
<rule id="100210" ...>  (Vault VM blocked correlation, level 6)
```

If you want to keep rule ID 100200 for backward compatibility (e.g. saved dashboards), the new rule chain uses 100250 / 100251 / 100252 / 100253 instead, so 100200 is free to retire.

Validate + restart the manager:

```bash
sudo /var/ossec/bin/wazuh-analysisd -t
sudo systemctl restart wazuh-manager
```

## Operational notes

- **Start-from-now on first run**: the sidecar's first invocation skips the FTL DB's historical backlog (could be weeks of queries) by starting from `MAX(id)`. Subsequent runs use the persisted `last_seen_id` from `/var/lib/pihole-ftl-tail/last_seen_id`. If you ever want to backfill a chunk of history, stop the daemon, edit the state file to a lower id, restart.
- **logall_json disk usage**: `archives.json` grows fast (one line per decoded event, all clients on the LAN if you have other localfiles tailing). The default `/etc/logrotate.d/wazuh` config handles it, but worth a `du -sh /var/ossec/logs/archives/` after the first week to confirm.
- **wazuh-archives-* index growth**: with archives ingestion enabled (step 5), the indexer also accumulates a parallel index for every decoded event. No automatic ILM by default; check disk on the indexer node periodically and either set up an ILM policy or manually prune old daily indices. See Wazuh's docs on index lifecycle management for the standard approach.
- **Vault VM IP is hardcoded** in two places: `CLIENT_FILTER` near the top of `pihole-ftl-tail.py` (filters at SQL level so non-Vault events don't even hit the JSON log), and `<srcip>` in rules 100251 / 100252 / 100253 (defense-in-depth; catches a misconfiguration where the SQL filter got changed). Pin a static lease in DHCP or set a static IP on the VM to avoid drift.
- **Pi-hole groups**: this stack relies on the LAN Pi-hole serving the Vault VM **without applying any blocklists** (Squid is the actual content gate). In Pi-hole's web UI, the Vault VM should be in a `vaultwarden-vm` group with **no adlists ticked**. See `Vaultwarden/README.md` § "Pi-hole groups, no DNS-layer blocking for the Vault VM".
- **Status code → label drift**: Pi-hole's FTL enum (`STATUS_LABELS` in the script) can shift across major versions. If you see events with `status=status-N` (raw integer fallback), Pi-hole emitted a code we don't have a label for; add it to the dict and restart the sidecar. The data is never lost: `status_code` is always the raw integer.
- **logrotate**: handled by `/etc/logrotate.d/vault-dns`, a host-side config not checked into the repo (matches the convention used for `vaultwarden` and `bunkerweb` logrotate configs in this stack). Canonical config text lives in `Vaultwarden/README.md` § "Log Rotation → LAN Pi-hole VM". Daily rotation, keep 14 compressed, `copytruncate` so the Wazuh agent's open fd stays valid across rotations. Picked up automatically by Debian's daily `logrotate` cron / systemd timer; nothing extra to schedule.

## ModSecurity events (BunkerWeb WAF)

BunkerWeb's `modsec_audit.log` is JSON, but Wazuh's JSON decoder collapses its `messages[]` array (where the matched rule IDs / severities live) into one opaque string. So a sidecar on the **Vault VM** flattens each transaction into one clean line first.

- `sidecar/vault/modsec-tail.py` , tails `/srv/bw-logs/modsec_audit.log`, emits flat events (`srcip`, `method`, `path`, `http_code`, `engine`, `rule_ids`, `anomaly_score`, `band`, ...) to `/var/log/modsec-events/events.log`. Runs as a dedicated unprivileged **`modsectail`** user (least privilege on the crown-jewels VM; the Pi-hole sidecar runs as root only because it reads a root-owned DB on a less-sensitive box). Byte-offset state for gap-free resume, IPv4/IPv6, stdlib only, no shell-out.
- `sidecar/vault/modsec-tail.service` , hardened systemd unit.
- `modsec/vault-modsec-agent.localfile.xml` , agent tails the events log.
- `modsec/manager-modsec-rules.xml` , rules 100300 (base, L0) / 100301 (band=none, L3) / 100302 (band=low|mid, L7) / 100303 (band=high, L11).

Tiering is by **CRS anomaly score** (rule 949110's "Total Score: N"), NOT http_code, which is backwards here: the heaviest multi-vector attacks hit `POST /` and return 404 while harmless missing-UA scans return 403. Discord fires on `band=high` (100303) only. Works identically before and after the engine flip (`DetectionOnly` -> `On`); the `engine` field rides along so the alert reads "would block" vs "blocked". Full rationale in the file headers.

## fail2ban bans (all hosts)

Every home VM running the sshd jail (vault, manager, proxy-home, pihole) tails its own `/var/log/fail2ban.log`; the manager decodes it and rule 100401 fires on a ban. The edge VPS runs fail2ban too but has no Wazuh agent, so its bans aren't shipped, the most internet-exposed host is the one gap in this picture.

- `fail2ban/fail2ban-agent.localfile.xml` , the `<localfile>` (add to every agent).
- `fail2ban/manager-fail2ban-decoder.xml` , custom `fail2ban-file` decoder. The **built-in** fail2ban decoder only handles syslog-delivered fail2ban (`program_name=fail2ban`); this stack tails the dedicated log, whose lines the built-in doesn't match (confirmed via `wazuh-logtest`). The prematch anchors on the `[pid]: LEVEL [jail]` structure, NOT the word "fail2ban", which the syslog pre-decoder strips as the program token. Captures jail / `f2b_action` / srcip (IPv4 + IPv6). It's `f2b_action` not `action` because `action` is a reserved Wazuh static field that a rule can't match with `<field>`.
- `fail2ban/manager-fail2ban-rules.xml` , 100400 (base, L0) / 100401 (ban, L10).

Discord fires on every ban (100401).

## Maintenance run summary (Vault VM `main.sh`)

The nightly maintenance run (`main.sh` → backup / docker-update / system-update / reboot) emits a structured JSON status log; the Vault VM agent ships it, and the manager turns the run rollup into one nightly #maintenance Discord report (a green OK heartbeat, or an @ on degraded/fail). This is the Phase A work from `Vaultwarden/ideas.md` idea #7. The external `DEADMAN_URL` stays as the independent "did it run at all" net, a completed-run summary can't catch a run that never happened.

- `scripts/root_scripts/lib.sh` `emit_status` , printf-built JSON (no jq dep to emit), one line per phase to `/srv/logs/status/vault-maint-status.jsonl` (`event_type=vault_maint`, `phase`, `status`, `rc`, + detail). `status_init` arms an EXIT trap so every phase reports even on an unexpected exit.
- `scripts/root_scripts/main.sh` `emit_run_summary` , rolls the per-phase lines into a final `phase=run` event (jq-aggregated: overall status, backup size, image names updated, pull failures, apt package names, ...). **Emitted BEFORE the reboot phase, not from an exit trap**: an immediate `reboot -h now` races the shutdown and the agent is stopped before it can ship the summary, so it's emitted while the VM is fully up (reboot reads "scheduled"). A blocked-reboot branch fires a separate 🔴 alert (gate blocked the reboot → containers left stopped → Vaultwarden down).
- `maintenance/vault-maint-agent.localfile.xml` , the Vault VM agent `<localfile>`. It points at the single file `/srv/logs/status/vault-maint-status.jsonl` (NOT dated): the agent keeps a persistent tail position there and ships the nightly line even though the run reboots ~5s after writing it. A dated, new-each-day file isn't picked up in that window and the line is lost (the first cron night produced no Discord because of exactly that). Retention is host-side logrotate copytruncate.
- `maintenance/manager-maint-rules.xml` , 100500 (base, L0) / 100501 (run ok, L3) / 100502 (run degraded|fail, L11).

The run rules match a **derived `vw_sev`** field (`info`/`warn`), NOT `status`: Wazuh reserves `status` as a static field a rule can't match with `<field>` (same trap as fail2ban's `f2b_action`; `analysisd -t` errors "Field 'status' is static" and the manager won't start). `emit_run_summary` sets `vw_sev=info` when the overall is ok, else `warn`. `status` still rides along (read as `data.status` for the embed + `$(status)` in the description). `main.sh` needs `jq` for the rollup; the per-phase emit does not.

## Discord notifications (custom-discord integrator)

`integrations/custom-discord.py` is one Wazuh integrator all five sources route through. It holds a **per-channel webhook map** (placeholders in the repo; the real URLs live in a gitignored `discord-webhooks.json` side-file on the manager, mode `0640 root:wazuh`, whose keys override the placeholders at startup, so re-installing the script never clobbers them, fill them once) and applies the final data-field filter each source needs (dns: `status=blocked-regex`; squid: `action=TCP_DENIED`; modsec: `band=high`; fail2ban: rule 100401; maintenance: rules 100501/100502, @ only when `status != ok`). It posts native Discord embeds (GeoIP-enriched for public source IPs), stdlib-only (urllib).

- `integrations/custom-discord.py` , install at manager `/var/ossec/integrations/custom-discord` (mode 0750, `root:wazuh`; note: no `.py`, that's the name integratord calls).
- `integrations/manager-discord-integration.xml` , the `<integration>` blocks (one per source, scoped by group / rule_id / level) for the manager's `ossec.conf`.

Gotcha baked into the script: Discord's API is Cloudflare-fronted and **403s the default `Python-urllib` User-Agent**, so `send_discord` sets a `DiscordBot (...)` UA. The manager needs egress to `discord.com:443`.

## What's still ahead

The DNS allowlist-anomaly alerting once sketched here is done (Pi-hole regex + rule 100252, above), and the Vault VM maintenance-status pipeline is now live (JSON status log → rules 100500-100502 → #maintenance, see above). Remaining Wazuh build-out, tracked in `Vaultwarden/ideas.md` idea #7:

- The **no-run-in-25h** deadman-equivalent rule (alert when no `phase=run` event arrives within 25h). NOT built, and awkward in Wazuh (rules fire on an event, not on its absence; and if the VM is dead the agent is too, so an on-box rule can't fire for the case that matters most). `DEADMAN_URL` stays as the external net for "the run never happened" rather than being replaced.
- Agent-down notifications (rule 504). Investigated and parked: the nightly reboots show as clean stop/start (506/503) within the ~10-min disconnect threshold so they don't false-fire, but the channel isn't wired.
- Shipping the Vault VM's own `vw-logs/` + `bw-logs/` and FIM on `/srv/vw-data`, compose files, etc.
