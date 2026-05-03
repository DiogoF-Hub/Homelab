# Wazuh DNS visibility for the Vaultwarden VM

This folder holds the Wazuh-side configuration that gives full visibility into every DNS query the Vaultwarden VM makes, by routing the VM's DNS through the homelab's existing LAN Pi-hole, tailing Pi-hole's FTL SQLite database with a small sidecar daemon, and shipping structured per-query events into Wazuh.

It is the successor to two earlier iterations:

1. The original "dnsproxy on the proxy-home VM" setup, retired when DNS visibility moved up the stack into Wazuh.
2. The first "Wazuh on Pi-hole's text log" iteration, retired because Pi-hole's dnsmasq text log emits four-plus different syntactic patterns for "this query was blocked" depending on the source (gravity adlist, manual exact-deny, regex, blocked-upstream-NULL, externally-blocked NXDOMAIN, ...). Building decoder regex that catches them all and stays correct across Pi-hole versions was whack-a-mole. The current FTL-DB approach reads Pi-hole's normalized `status` integer column instead.

## Why this exists

Two things the Vault VM gets out of this:

1. **Visibility**: every DNS query the VM makes (Let's Encrypt endpoints, Cloudflare tunnel, CrowdSec hub, apt mirrors, the Vaultwarden domain itself, Wazuh feeds) shows up as a Wazuh alert in the dashboard, scoped to the Vault VM's source IP, with full per-query metadata (qtype, query, status, blocked-or-not). If the host gets compromised and starts phoning home, the resolution attempt is captured before egress even tries.
2. **DoH-encrypted upstream + Family-DNS filtering**, inherited from Pi-hole's existing `adguard/dnsproxy` upstream. Same upstream encryption story as the old dedicated-DoH-gateway setup, no plaintext-on-LAN sniffability.

What this **doesn't** do (yet): alert on *unexpected* domains specifically. Right now every Vault VM DNS query produces a level-3 alert (resolved) or level-6 alert (blocked). The next iteration will add per-domain allowlist matching against the Squid allowlist (`Vaultwarden/proxy-home/vault_domains_allow_proxy.txt`), generating a higher-level alert only on misses. Sketched below under "Planned next step"; full design tracked in `Vaultwarden/ideas.md` idea #7 Phase C.

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
| `sidecar/pihole-ftl-tail.py` | Install at **Pi-hole VM** `/usr/local/sbin/pihole-ftl-tail.py` | The daemon. Reads Pi-hole's FTL DB, emits structured JSON events. ~200 lines, stdlib only |
| `sidecar/pihole-ftl-tail.service` | Install at **Pi-hole VM** `/etc/systemd/system/pihole-ftl-tail.service` | Systemd unit running the daemon as root with hardening (`ProtectSystem`, `RestrictAddressFamilies=AF_UNIX`, etc.) |
| `pihole-agent.localfile.xml` | Append to a `<ossec_config>` block in **Pi-hole VM** `/var/ossec/etc/ossec.conf` | Tells the Wazuh agent to tail the sidecar's `/var/log/vault-dns/events.log` (JSON format) |
| `manager-global.snippet.xml` | One-line addition inside the `<global>` block in **wazuh-home** `/var/ossec/etc/ossec.conf` | Enables `logall_json` so level-0 events (rule 100250 base) land in `archives.json` and are searchable. Pair with `archives.enabled: true` in `/etc/filebeat/filebeat.yml` to also expose them as `wazuh-archives-4.x-*` in the dashboard (see deploy step 5) |
| `manager-rules.xml` | Append inside **wazuh-home** `/var/ossec/etc/rules/local_rules.xml` | Four-rule chain: 100250 (archive base) + 100251 (resolved) + 100252 (Pi-hole policy block) + 100253 (upstream no-answer) |

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
sudo install -m 0755 sidecar/pihole-ftl-tail.py     /usr/local/sbin/pihole-ftl-tail.py
sudo install -m 0644 sidecar/pihole-ftl-tail.service /etc/systemd/system/pihole-ftl-tail.service

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

Append the `<ossec_config>` block from `pihole-agent.localfile.xml` to `/var/ossec/etc/ossec.conf` (the agent merges multiple `<ossec_config>` blocks at the top level). Restart:

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
# if missing, add <logall_json>yes</logall_json> inside <global>; see manager-global.snippet.xml

# install the rules
sudo nano /var/ossec/etc/rules/local_rules.xml
# append the contents of manager-rules.xml (the <group name="dns,pihole,vaultwarden"> block)

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

If you'd rather skip this step, the alternative is to bump rule 100250's level from 0 to ~5 in `manager-rules.xml`. Then catch-all events fire alerts directly into `wazuh-alerts-*`, no archives ingestion needed. Less infrastructure but only DNS-event visibility, not the broader Wazuh stream.

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

## Planned next step (not yet implemented)

Right now every Vault VM DNS query is alerted at level 3 (resolved) or level 6 (blocked). The next iteration adds **allowlist-anomaly detection**:

- A fourth rule (e.g. 100253, level 7) fires when the resolved query's domain is NOT on the Squid allowlist (`Vaultwarden/proxy-home/vault_domains_allow_proxy.txt`).
- Implementation option: extend the sidecar to read the allowlist file at startup (and on SIGHUP), set an extra boolean field `allowed: true|false` on each event, and add a rule that filters on `allowed=false`. Avoids needing a Wazuh integrator entirely; keeps the merge in one place.
- Alternative: use Wazuh's `<integration>` daemon to invoke a script per 100251 alert (less efficient but doesn't require touching the sidecar).

Full design: `Vaultwarden/ideas.md` idea #7, Phase C, subsection "Allowlist-anomaly alert for the Vault VM".
