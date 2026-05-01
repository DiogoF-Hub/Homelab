# Wazuh DNS visibility for the Vaultwarden VM

This folder holds the Wazuh-side configuration that gives full visibility into every DNS query the Vaultwarden VM makes, by routing the VM's DNS through the homelab's existing LAN Pi-hole and shipping Pi-hole's query log into Wazuh.

It is the successor to the previous "dnsproxy on the proxy-home VM" setup. Instead of running a dedicated DoH gateway purely for the Vault VM, the Vault VM now uses the same Pi-hole every other LAN client uses, and the audit trail moves up the stack into Wazuh.

## Why this exists

Two things the Vault VM gets out of this:

1. **Visibility**: every DNS query the VM makes (Let's Encrypt endpoints, Cloudflare tunnel, CrowdSec hub, apt mirrors, the Vaultwarden domain itself, Wazuh feeds) shows up as a level-3 alert in the Wazuh dashboard, scoped to the Vault VM's source IP. If the host gets compromised and starts phoning home to anything, the resolution attempt is captured before egress even tries.
2. **DoH-encrypted upstream + Family-DNS filtering**, inherited from Pi-hole's existing `adguard/dnsproxy` upstream. Same upstream encryption story as the old setup, no plaintext-on-LAN sniffability.

What this **doesn't** do (yet): alert on *unexpected* domains specifically. Right now every Vault VM DNS query is a level-3 alert. The next iteration will run a Wazuh integrator script that cross-checks each query against the Squid allowlist (`proxy-home/vault_domains_allow_proxy.txt`) and only alerts on misses. That part is staged in this folder's design but not yet implemented.

## Architecture

```
Vaultwarden VM (192.168.50.3, VLAN-DMZ)
  /etc/resolv.conf -> 192.168.173.2
              │
              │  UDP/53 (DMZ -> LAN; OPNsense pass rule)
              ▼
LAN Pi-hole VM (192.168.173.2)
  ├─ pihole-FTL (dnsmasq)
  │     └─ writes /var/log/pihole/pihole.log (host bind mount, see PiHole/docker-compose.yml)
  ├─ adguard/dnsproxy (sidecar, DoH upstream to Cloudflare Family)
  └─ wazuh-agent
        └─ tails /var/log/pihole/pihole.log
              │
              │  encrypted to manager
              ▼
wazuh-home (manager)
  ├─ custom decoder  pihole-dnsmasq-query  (manager-decoder.xml)
  │     extracts qtype, query, srcip from query[*] lines
  ├─ rule 100190 level 0  (every Pi-hole DNS query, archived only)
  └─ rule 100200 level 3  (only Vault VM srcip, alerts in dashboard)
```

## Files in this folder

| File | Where it goes | What it does |
|------|---------------|--------------|
| `pihole-agent.localfile.xml` | Append to a `<ossec_config>` block in **Pi-hole VM** `/var/ossec/etc/ossec.conf` | Tells the agent on the Pi-hole VM to tail `pihole.log` and `FTL.log` |
| `manager-global.snippet.xml` | One-line addition inside the `<global>` block in **wazuh-home** `/var/ossec/etc/ossec.conf` | Enables `logall_json` so level-0 events (rule 100190) land in `archives.json` and are searchable |
| `manager-decoder.xml` | Append inside **wazuh-home** `/var/ossec/etc/decoders/local_decoder.xml` | Custom dnsmasq decoder. Wazuh's stock ruleset has no dnsmasq decoder; without this, query lines fall through to `NO_DECODER` |
| `manager-rules.xml` | Append inside **wazuh-home** `/var/ossec/etc/rules/local_rules.xml` | The two-rule chain (100190 archive-only base + 100200 Vault-VM-srcip alert) |

These are reference snippets, not deployable files. The actual files on each VM (`ossec.conf`, `local_decoder.xml`, `local_rules.xml`) carry stock Wazuh content that we don't replace; we only append our additions.

## Apply order

Best to do this in roughly this order so each step is verifiable before the next:

### 1. On the Pi-hole VM

Make sure the Pi-hole compose has a host bind mount for the log directory. The current compose in `PiHole/docker-compose.yml` already includes:

```yaml
volumes:
  - /var/log/pihole:/var/log/pihole
```

If it isn't there yet, add it, recreate the container (`docker compose up -d --force-recreate`), and verify `sudo tail -f /var/log/pihole/pihole.log` shows live queries.

Install the Wazuh agent (apt repo + enrolment with your `wazuh-home` manager; standard Wazuh install procedure). Then add the localfile blocks from `pihole-agent.localfile.xml` to `/var/ossec/etc/ossec.conf` and restart:

```bash
sudo systemctl restart wazuh-agent
sudo grep "pihole.log" /var/ossec/logs/ossec.log | tail
# expect: Analyzing file: '/var/log/pihole/pihole.log'
```

### 2. On wazuh-home (manager)

Three files to edit, validate-then-restart at the end:

```bash
# 1. enable archive logging (needed so rule 100190 events are searchable)
sudo nano /var/ossec/etc/ossec.conf
#   add <logall_json>yes</logall_json> inside <global>

# 2. install the custom decoder
sudo nano /var/ossec/etc/decoders/local_decoder.xml
#   append the contents of manager-decoder.xml

# 3. install the custom rules
sudo nano /var/ossec/etc/rules/local_rules.xml
#   append the contents of manager-rules.xml

# validate before reloading; analysisd -t parses without starting the daemon
sudo /var/ossec/bin/wazuh-analysisd -t

# if clean, restart the manager
sudo systemctl restart wazuh-manager
```

If `analysisd -t` reports an error, fix the file before restarting, otherwise the manager won't come back up cleanly.

### 3. Network plumbing

- **OPNsense rule**: pass `192.168.50.0/24 -> 192.168.173.2` on TCP+UDP port 53. Without this the Vault VM's queries never reach Pi-hole and the alerts will be empty.
- **Vault VM `/etc/resolv.conf`**: `nameserver 192.168.173.2`. Make it survive reboots via whatever manages networking on the VM (`/etc/network/interfaces`, netplan, systemd-resolved drop-in).

### 4. Verify end-to-end

```bash
# from the Vault VM
nslookup github.com 192.168.173.2

# on wazuh-home
sudo tail -f /var/ossec/logs/alerts/alerts.json \
  | jq -r 'select(.rule.id=="100200") | "\(.timestamp) \(.data.qtype) \(.data.query) from \(.data.srcip)"'
```

Within a couple of seconds the alert should appear with `qtype=A` (and probably also a parallel `AAAA`) for the queried domain. That's the full pipeline working.

## Offline test (no live traffic needed)

`wazuh-logtest` lets you feed sample log lines directly to the rule engine without involving any agent or Pi-hole:

```bash
sudo /var/ossec/bin/wazuh-logtest
```

Then paste a sample line such as:

```
May  1 15:00:32 dnsmasq[52]: query[A] github.com from 192.168.50.3
```

You should see decoder `pihole-dnsmasq-query` matched in phase 2 and rule 100200 firing in phase 3. A line with a non-Vault srcip like `192.168.173.35` should match decoder + rule 100190 only (level 0, no alert).

Useful when iterating on the decoder regex or testing a different srcip filter, no manager restart needed.

## Operational notes

- **One alert per query type**: most modern resolvers send A and AAAA in parallel for the same hostname. Each is a separate dnsmasq query line, each fires rule 100200, so a single user-facing lookup typically produces two alerts. Not a bug, just the cost of decoding individual query records faithfully.
- **logall_json disk usage**: `archives.json` grows fast (one line per decoded event, all clients on the LAN). The default `/etc/logrotate.d/wazuh` config handles this, but worth a `du -sh /var/ossec/logs/archives/` after the first week to confirm it's behaving.
- **Vault VM IP is hardcoded**: rule 100200 has the IP literal `192.168.50.3` in `<srcip>`. If the VM ever moves, the rule needs updating. Pin a static lease in DHCP or set a static IP on the VM to avoid drift.
- **Pi-hole groups**: this stack relies on the LAN Pi-hole serving the Vault VM **without applying any blocklists** (Squid is the actual content gate). In Pi-hole's web UI, create a `vaultwarden-vm` group, add the Vault VM as a client to that group, and in **Group Management -> Adlists** untick all blocklists for the group. Result: the Vault VM gets resolution + DoH upstream + logging, but no DNS-layer blocking that could cause a hard-to-diagnose outage when an apt mirror or container registry suddenly becomes "blocked" by a community blocklist.

## Planned next step (not yet implemented)

Move from "every Vault VM DNS query is a level-3 alert" to "only **unexpected** domains trigger a higher-level alert." Sketch:

- Wazuh integrator (`<integration>` block in `ossec.conf`) hooks rule 100200; integratord invokes a small Python script per matching alert.
- Script reads the canonical Squid allowlist (`Vaultwarden/proxy-home/vault_domains_allow_proxy.txt`, mirrored onto wazuh-home), parses entries (exact FQDNs + apex `.example.com` wildcards), and checks each query.
- Misses get appended to `/var/log/vault-dns-anomaly.log` on wazuh-home; the local agent on wazuh-home tails that file; a new rule (e.g. 100220, level 7) fires per anomaly.
- Allowlist syncs from this repo (manual, cron, or post-deploy hook depending on workflow).

End state: rule 100200 keeps the full archived stream of Vault VM lookups; rule 100220 is the actual "this is unusual" signal that an operator pays attention to.
