# Pi-hole Setup

This folder contains my **Docker-based Pi-hole configuration and automation scripts**, running on a dedicated **Ubuntu Server VM in Proxmox** on the LAN.

It is a **two-container stack**, not just Pi-hole:

* **`pihole`** does the blocking, the local DNS records, and the HTTPS-only web interface
* **`dnsproxy`** ([`adguard/dnsproxy`](https://github.com/AdguardTeam/dnsproxy)) sits behind it as a **DNS-over-HTTPS forwarder** to Cloudflare Family, bound to loopback only

Both run with `network_mode: host`, so nothing leaves the box as plaintext DNS except the two bootstrap lookups that resolve the DoH endpoint itself.

This Pi-hole is also the **DNS chokepoint for the Vaultwarden VM** (see [`../Vaultwarden/README.md`](../Vaultwarden/README.md)), with every query from that VM shipped into Wazuh as an alert.

Everything here is public for transparency and to help others learn, but you **must adapt the configuration to your own environment** before using it. The IPs, hostnames, and tailnet name in `docker-compose.yml` are **example values**.

---

## 📂 Structure

```
PiHole/
├── .env                      # FTLCONF_webserver_api_password (committed EMPTY, see warning below)
├── docker-compose.yml        # The whole stack: dnsproxy + pihole, fully env-configured
├── blocklist.txt             # 70 adlist URLs, paste into Adlists
├── cookielist_whitelist.txt  # 223 cookie-consent (CMP) domains to allowlist
├── manual_domains_block.txt  # REGEX blacklist entries (not exact domains)
├── mycustom_list.txt         # 27 exact domains to block
├── main.sh                   # Nightly maintenance, run by root cron. ENDS IN A REBOOT
├── start-containers.sh       # @reboot bring-up, also what deploys freshly pulled images
├── root_crontab.txt          # The two root crontab entries
└── README.md                 # This documentation
```

Two paths live on the **host**, not in the repo, and both have to exist:

| Host path | What it is |
| --------- | ---------- |
| `/home/pi/pihole/` | Where the compose stack is deployed. Hardcoded in both scripts, so don't move it. |
| `/home/pi/pihole/data/etc-pihole/` | Bind mount for `/etc/pihole` (gravity DB, FTL DB, TLS cert). **Create it before the first `up`.** |
| `/mnt/truenas-logs/pihole/` | TrueNAS NFS mount where `main.sh` writes its logs. If it isn't mounted, the logs go nowhere useful. |

---

## 🌐 DNS Flow

```
LAN clients ─────────────────────┐
Vaultwarden VM ──────────────────┤
                                 ├──> Pi-hole :53
guest wifi ──> OPNsense Unbound ─┘        │  blocking, local records, query log
               (192.168.173.1)            │
                                          │  upstream = 127.0.0.1#5335
                                          ▼
                                     dnsproxy :5335  (loopback only)
                                          │
                                          │  DoH
                                          ▼
                          https://family.cloudflare-dns.com/dns-query
```

Most clients point **straight at Pi-hole**. The guest wifi is the exception: those devices resolve through OPNsense Unbound, which forwards to Pi-hole. That one indirect path is what drives the rate-limiting choice further down.

`1.1.1.1` / `1.0.0.1` appear in the compose as **bootstrap only**. They resolve the hostname `family.cloudflare-dns.com` at startup, they are not used to answer client queries. Actual resolution is Cloudflare **Family** (malware + adult filtering), encrypted end to end.

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

Only one variable:

```bash
FTLCONF_webserver_api_password=YourStrongPassword
```

> ⚠️ **`PiHole/.env` is tracked by git and is NOT in `.gitignore`.** It is committed with an empty value on purpose. Fill it in on the VM, but don't commit the filled-in version.

---

### **`dnsproxy` service**

```yaml
command: >
  -l 127.0.0.1
  -p 5335
  -u https://family.cloudflare-dns.com/dns-query
  -b 1.1.1.1:53
  -b 1.0.0.1:53
  --cache
```

| Flag | Why |
| ---- | --- |
| `-l 127.0.0.1` | Loopback only. With host networking this is what keeps it off the LAN. |
| `-p 5335` | Non-standard port, stays clear of Pi-hole on 53. |
| `-u` | Upstream DoH endpoint. |
| `-b` | Plain-DNS bootstrap, used once to resolve the DoH hostname. |
| `--cache` | Local cache, cuts repeat round trips to Cloudflare. |

---

### **`pihole` service**

Everything is configured through `FTLCONF_*` environment variables rather than through the web UI.

> **Important:** any setting supplied via `FTLCONF_*` becomes **read-only in the web UI and CLI**. That applies to all of them, not just the array ones. For `FTLCONF_dns_hosts` in particular the array **replaces** the UI list entirely, so every local DNS record you want has to be in compose.

#### Local DNS

| Variable | Purpose |
| -------- | ------- |
| `FTLCONF_dns_domain_name` | Local DNS domain (`localdomain`). |
| `FTLCONF_dns_hosts` | Local A/AAAA records, `IP HOSTNAME [HOSTNAME ...]` per line. Router, switch, NAS, proxy. |
| `FTLCONF_dns_revServers` | Reverse servers (what used to be called conditional forwarding). Sends PTR lookups for a range to the server that actually knows the names. Format: `<enabled>,<range>,<server>[#port][,<domain>]`. |

The `dns_hosts` array also **sinkholes wpad** (`0.0.0.0` / `::` for `wpad` and `wpad.localdomain`). That's generic hardening, keep it: it stops a hostile network from serving a Web Proxy Auto-Discovery PAC file that would silently reroute traffic.

`revServers` covers the two local `/24`s, both pointed back at OPNsense because it's also the DHCP server and therefore the only thing that knows the lease-to-name mapping, plus the Tailscale CGNAT range `100.64.0.0/10` pointed at MagicDNS on `100.100.100.100`.

#### Privacy / noise

| Variable | Purpose |
| -------- | ------- |
| `FTLCONF_dns_bogusPriv` | Answers private-range PTR lookups locally with NXDOMAIN instead of forwarding them, so internal network layout never leaks upstream. `revServers` still wins for the ranges it covers. |
| `FTLCONF_webserver_api_excludeDomains` | Hides matching domains from Top Domains and the Query Log **without blocking them**. Regex, one per line. Used for wpad noise and Bonjour `_dns-sd._udp` service discovery chatter. |
| `FTLCONF_dns_specialDomains_iCloudPrivateRelay` | `false`, so iCloud Private Relay is not blocked. Mostly to kill the persistent dashboard warning. |

> **Backslash gotcha:** the escaping rule differs by where you write the regex.
> * **Env var / compose:** single backslash, e.g. `^wpad\.`. FTL does no unescaping on env values, it stores the raw bytes.
> * **`pihole.toml`:** doubled, e.g. `^wpad\\.`, because TOML basic strings process escapes.
> * **Web UI textarea:** single backslash.
>
> A doubled backslash in the env var still compiles as a valid regex (escaped literal backslash + any-char), so FTL logs no error, it just silently never matches anything.

#### Rate limiting

`FTLCONF_dns_rateLimit_count` and `FTLCONF_dns_rateLimit_interval` are both `0`, which disables rate limiting.

This is deliberate and it is a real tradeoff. Pi-hole rate limits **per source IP**. Direct clients each get their own budget, which is fine, but everything from the **guest wifi arrives via OPNsense Unbound as a single source IP**. The whole guest network's aggregate volume lands in one bucket and trips the default 1000/60s limit, which would blackhole guest DNS entirely.

Disabling it is the blunt fix. If nothing in your network reaches Pi-hole through a forwarder, leave the defaults alone.

#### Reachability

`FTLCONF_dns_listeningMode: 'all'`, `FTLCONF_dns_reply_host_IPv4`, and `FTLCONF_dns_reply_host_force4` are the three that make `pi.hole` resolve reliably over **Tailscale**, together with `network_mode: host`. Without them the interface name resolves inconsistently depending on which interface the query came in on.

(`FTLCONF_dns_reply_host_IPv4` is spelled with the canonical capitalization from `pihole.toml`. FTL's env lookup is case-insensitive after the `FTLCONF_` prefix, so `_ipv4` works too, but matching the canonical form is the better habit.)

#### Other

| Variable | Purpose |
| -------- | ------- |
| `TZ` | `Europe/Luxembourg`, so the query log timestamps make sense. |
| `FTLCONF_ntp_sync_server` | Pi-hole syncs time from OPNsense rather than `pool.ntp.org`. |
| `FTLCONF_dns_upstreams` | `127.0.0.1#5335`, the dnsproxy listener. |
| `FTLCONF_webserver_port` | `443s`. HTTPS only, no port 80 listener. Note there's no `o` (optional) flag, so failing to bind 443 is a hard startup error rather than something FTL shrugs off. |

#### Capabilities

| Capability | Why |
| ---------- | --- |
| `SYS_TIME` | Lets FTL set system time as an NTP client. |
| `CHOWN` | Fixes ownership on `/etc/pihole` at startup. |
| `NET_BIND_SERVICE` | Binds privileged ports 53 and 443. |
| `SYS_NICE` | Raises FTL scheduling priority. |

#### Ports

There is **no `ports:` block**. `network_mode: host` means the containers bind host ports directly:

* **53** tcp+udp, DNS
* **443** tcp, web interface
* **123** udp, NTP
* **5335** tcp+udp on loopback, dnsproxy

Because of that, the VM must have nothing else on 53 or 443. On Ubuntu that means **disabling the `systemd-resolved` stub listener** before the first `up`, or the Pi-hole container will fail to bind.

---

### **Custom User Files**

| File | Contents | Where it goes in Pi-hole |
| ---- | -------- | ------------------------ |
| **`blocklist.txt`** | 70 adlist URLs, one per line, no comments. | Adlists. Paste-ready as is. |
| **`cookielist_whitelist.txt`** | 223 unique cookie-consent platform (CMP) domains, grouped by vendor. Prevents consent banners from hanging or hiding page content. | Allowlist (exact). **Strip the inline `# ...` comments and `# ----` dividers first.** |
| **`manual_domains_block.txt`** | A **regex**, `(^|\.)xn--`, blocking IDN / punycode domains. | **Regex** blacklist, not the exact-domain one. |
| **`mycustom_list.txt`** | 27 exact domains (ad networks, analytics, telemetry), with `#` section headers. | Blacklist (exact). Strip the headers. |

> Known conflict: `pagead2.googlesyndication.com` is in **both** `mycustom_list.txt` (block) and `cookielist_whitelist.txt` (allow, needed for banner display). Allowlist wins in Pi-hole, so the block entry is dead by design.

---

## 🛠 Scripts

| Script | Purpose |
| ------ | ------- |
| **`start-containers.sh`** | `docker compose up -d --force-recreate` from `/home/pi/pihole`. Runs `@reboot` via root cron. The `--force-recreate` is what actually **deploys the images `main.sh` pulled**, so it's the second half of the update cycle, not just a boot script. |
| **`main.sh`** | Nightly maintenance, run by root cron at **04:15**. |

### What `main.sh` actually does

1. **Gravity update**: `docker compose exec pihole pihole -g`
2. **Stop the stack**: `docker compose down`, then polls up to 30s for every service to actually be stopped
3. **Image update**: for each service, compares local vs pulled image ID, pulls with 3 retries, `docker rmi -f` on the superseded image. It **does not bring the stack back up.**
4. **System update**: `dpkg --configure -a`, `apt-get update`, `openssh-server` upgraded with `UCF_FORCE_CONFFOLD=1` (keeps existing config), `upgrade`, `full-upgrade`, `autoremove --purge`, `clean`
5. **`reboot -h now`** unconditionally

> ⚠️ Two things worth knowing before you copy this:
> * **DNS is down from step 2 until the box finishes rebooting.** The stack is deliberately not restarted mid-script; `start-containers.sh` brings it back at boot. Have a second resolver configured on your clients or DHCP.
> * **The reboot is unconditional**, not "if a kernel update landed".

Logs, each with 30-day retention pruning:

```
/mnt/truenas-logs/pihole/gravity/gravity-update-YYYY-MM-DD.log
/mnt/truenas-logs/pihole/docker/update-YYYY-MM-DD.log
/mnt/truenas-logs/pihole/system/system-autoupdate-YYYY-MM-DD.log
```

`root_crontab.txt`:

```cron
@reboot /home/pi/pihole/start-containers.sh > /dev/null 2>&1
15 4 * * * /home/pi/pihole/main.sh
```

Both entries must be in **root's** crontab. `main.sh` runs `apt-get` and `reboot` with no `sudo`, so it fails as a normal user.

---

## 🚀 Deployment Steps

1. **Prepare the host**

   ```bash
   sudo mkdir -p /home/pi/pihole/data/etc-pihole
   ```

   Free up port 53 by disabling the `systemd-resolved` stub listener, and make sure nothing else holds 443. Mount `/mnt/truenas-logs` (or edit `LOG_DIR` in `main.sh`).

2. **Adapt `docker-compose.yml` to your network**

   At minimum: `FTLCONF_dns_hosts`, `FTLCONF_dns_revServers`, `FTLCONF_dns_reply_host_IPv4`, `FTLCONF_ntp_sync_server`, and `TZ`. The shipped values are examples from my LAN.

3. **Set your password**

   ```bash
   # PiHole/.env
   FTLCONF_webserver_api_password=YourStrongPassword
   ```

4. **Start the stack (first run only)**

   ```bash
   docker compose up -d
   ```

   Sanity check that FTL consumed every variable:

   ```bash
   docker logs pihole 2>&1 | grep FTLCONF
   ```

   It prints an `N FTLCONF environment variables found (X used, Y invalid, Z ignored)` line, plus "did you mean" suggestions for anything it didn't recognize.

5. **Load the crontab entries**

   ```bash
   sudo crontab -e
   ```

   Paste the contents of `root_crontab.txt`.

6. **Access the web interface**

   * URL: `https://pi.hole/admin`
   * Password: the one from `.env`
   * The cert is **self-signed**, so expect a browser warning. Import Pi-hole's cert, or issue one from your own CA (see [`../HTTPS Generator/`](../HTTPS%20Generator/)).

7. **Add blocklists, domains, and the allowlist**

   * Adlists from `blocklist.txt`
   * Exact blocks from `mycustom_list.txt`
   * The regex from `manual_domains_block.txt` into the **regex** blacklist
   * Allowlist from `cookielist_whitelist.txt`

   Local DNS records are **not** part of this step, they come from compose and that UI page is read-only.

---

## 🔒 Security Features

* **Encrypted upstream.** All resolution goes out over DoH to Cloudflare Family. No plaintext DNS leaves the box apart from the two bootstrap lookups.
* **Resolver bound to loopback.** `dnsproxy` listens on `127.0.0.1:5335` only, so nothing off-box can use it as an open resolver even under host networking.
* **HTTPS-only web interface** on 443, no port-80 listener. Self-signed by default, so treat it as transport encryption rather than authenticated identity until you install a proper cert.
* **wpad sinkholed** at the DNS layer, blocking hostile PAC-file delivery.
* **`bogusPriv`**, so private-range reverse lookups are never forwarded upstream and the internal network layout stays internal.
* **Filtering upstream**, malware and adult content dropped by Cloudflare Family before Pi-hole's own blocklists even come into play.
* **Unattended patching** with a nightly full system upgrade and reboot.

Honest caveats:

* **Rate limiting is off** (see above), because the guest network reaches Pi-hole through OPNsense Unbound and would otherwise trip the per-IP limit as one oversized client.
* **Nightly DNS outage** during the maintenance window.
* **`.env` is tracked in git.** Keep the committed value empty.

---

## 🔗 Related

* [`../Vaultwarden/README.md`](../Vaultwarden/README.md), the Vault VM uses this Pi-hole as its only DNS path, with a group-scoped allowlist (`vault_domains_allow_dns.txt`) and full per-query Wazuh visibility
* [`../HTTPS Generator/README.md`](../HTTPS%20Generator/README.md), for issuing an internal-CA cert for the web interface
