# Vaultwarden Setup

This folder contains my **Vaultwarden configuration and automation scripts**, running on **rootless [Podman](https://podman.io/)** with a dedicated non-privileged user (`poduser`).

The reverse proxy / WAF / bouncer layer was previously **Caddy + Certbot + Cloudflare Workers bouncer (host-installed CrowdSec)**, and is now a single **[BunkerWeb](https://www.bunkerweb.io/) all-in-one container** that handles ACME (Let's Encrypt), TLS termination, security headers, country blacklist, user-agent blacklist, rate limiting, ModSecurity/CRS WAF, and the CrowdSec bouncer in one place. CrowdSec itself is also now containerized.

All container orchestration runs through `podman-compose` under `poduser`; no docker daemon is installed or needed. (Earlier iterations of this stack on Ubuntu Server kept docker installed as a fallback parser because `podman-compose config --services` produced noisy output on older podman releases; on Debian 13 with podman 5.x the output is clean and the docker dependency was dropped.)

`poduser` has **no sudo privileges** and is not in any privileged group. To touch containers manually, drop into a poduser login shell with `sudo su - poduser` and run `podman-compose ...` directly. The non-interactive maintenance scripts use the equivalent `sudo -u poduser podman-compose ...` form. Either way, root-mediated user-switching is the only path in.

The setup is designed for **secure self-hosted password management**, with:

* **[Cloudflare Tunnel (`cloudflared`)](#-cloudflare-tunnel)** as the public-facing edge, no host ports exposed; all inbound traffic arrives via an outbound-initiated tunnel
* **[BunkerWeb reverse proxy + WAF](#%EF%B8%8F-bunkerweb-reverse-proxy--waf)** for HTTPS, security headers, ACME via DNS-01, CRS-based WAF, country/UA blacklists, rate limits, and the CrowdSec bouncer
* **[Containerized CrowdSec](#%EF%B8%8F-crowdsec-integration)** with custom Vaultwarden parsers, scenarios, and whitelists; bans enforced inline at BunkerWeb (no separate edge worker)
* **Outbound HTTP/HTTPS via [Squid on the `proxy-home` VM](#-outbound-httphttps-proxy--squid-on-the-proxy-home-vm)** (domain allowlist–enforced) and **[outbound DNS via the homelab's LAN Pi-hole](#-outbound-dns-via-the-lan-pi-hole--wazuh-visibility)**, with every Vault VM query shipped into Wazuh as a level-3 alert via a custom decoder + rule chain (see `wazuh-home/`)
* **[Daily automated maintenance](#-automation-scripts)** via `main.sh`: [age](https://github.com/FiloSottile/age)-encrypted backups [minisign](https://jedisct1.github.io/minisign/)-signed for tamper detection, image updates, full system update, and reboot
* **[Automated off-site replication](#-automation-scripts)** to TrueNAS and Hetzner Storage Box
* **Strict [Cloudflare](#cloudflare) security policies** for zero trust access
* **Full network isolation** by running on a dedicated VLAN with [strict firewall rules in OPNsense](#-dmz-firewall-rules)
* **Hosted on a dedicated Debian 13 VM in Proxmox** with dedicated NIC binding for VLAN isolation and full system backup capabilities
* **[Self-contained backup encryption](#-backup-and-redundancy)** using pinned [age](https://github.com/FiloSottile/age) binaries with version-controlled, reproducible, public-key-only encryption, and pinned [minisign](https://jedisct1.github.io/minisign/) binaries for cryptographic signing of every bundle


Everything here is public for transparency and to help others learn, but you **must adapt the configuration to your own environment** before using it.

---

## 📂 Structure

```
vaultwarden/
├── .env.template                              # Template showing which vars to set
├── DECRYPT.txt                                # Decryption instructions (also bundled with every backup)
├── README.md                                  # This documentation
├── ideas.md                                   # Numbered list of pending hardening / improvement ideas
│
├── docker-compose.dns-challenge.yml           # Production: behind Cloudflare Tunnel, ACME via DNS-01
├── docker-compose.http-challenge.yml          # Alternate: direct host-port exposure, ACME via HTTP-01
│
├── poduser_crontab.txt                        # Crontab entries for poduser (container @reboot startup)
├── root_crontab.txt                           # Crontab entries for root automation (nightly main.sh)
│
├── bunkerweb/                                 # Mounted into the BunkerWeb container
│   ├── security.txt                           # Vulnerability-reporting contact (served at /.well-known/security.txt)
│   ├── robots.txt                             # Disallows bots from indexing
│   └── custom-configs/                        # Mounted into BunkerWeb at /data/configs/ (its native ingest path)
│       ├── http/
│       │   └── headers-upstream-passthrough.conf  # http-scope map for upstream XFO/CSP passthrough
│       ├── server-http/
│       │   ├── headers-passthrough-apply.conf     # Owns ALL outbound security headers (HSTS, CSP, COOP, ...)
│       │   └── security-txt-lang.conf             # Per-path overrides for /robots.txt, /security.txt
│       ├── modsec/
│       │   └── exclusions-after-crs.conf          # Phase-3 (response-side) exclusions
│       └── modsec-crs/
│           ├── paranoia.conf                      # CRS detection / blocking paranoia level
│           └── exclusions-before-crs.conf         # Phase-1 (request-side) exclusions
│
├── crowdsec/                                  # Mounted into the CrowdSec container at the right stages
│   ├── acquis.d/                              # Per-source log acquisition definitions
│   │   ├── bunkerweb.yaml                     # Tails BunkerWeb access/error/modsec_audit logs
│   │   └── vaultwarden.yaml                   # Tails Vaultwarden's vaultwarden.log
│   ├── parsers/
│   │   └── vaultwarden-logs.yaml              # Custom parser (based on Dominic-Wagner's hub collection)
│   ├── scenarios/
│   │   └── vaultwarden-bf.yaml                # Custom bf + user-enum scenarios (tightened thresholds)
│   └── whitelists/
│       └── admin-diagnostics.yaml             # Drops Vaultwarden's intentional /admin/diagnostics 4xx probes
│
├── proxy-home/                                # Targets the proxy-home VM (HTTP/HTTPS egress chokepoint via Squid; DNS now uses the LAN Pi-hole instead, see wazuh-home/)
│   ├── squid.conf                             # Squid proxy configuration for domain allowlisting
│   └── vault_domains_allow_proxy.txt          # List of domains allowed for the Squid proxy
│
├── wazuh-home/                                # Targets the wazuh-home VM (Wazuh manager) + sidecar daemon for the LAN Pi-hole VM
│   ├── README.md                              # Architecture, apply order, verification, migration notes
│   ├── pihole-agent.localfile.xml             # <localfile> block for the Pi-hole VM's wazuh-agent (tails the sidecar's vault-dns/events.log)
│   ├── manager-global.snippet.xml             # logall_json toggle for the wazuh-home <global> block
│   ├── manager-rules.xml                      # Rules 100250 (base) + 100251 (resolved, level 3) + 100252 (Pi-hole policy block, level 6) + 100253 (upstream no-answer, level 4)
│   └── sidecar/
│       ├── pihole-ftl-tail.py                 # Daemon: polls Pi-hole's FTL SQLite DB, emits one structured JSON event per query
│       └── pihole-ftl-tail.service            # systemd unit (root, hardened, 10s polling tick)
│
├── vault_domains_allow_dns.txt                # Pi-hole allowlist for the vaultwarden-vm group (mirror of proxy-home/vault_domains_allow_proxy.txt in gravity/ABP syntax)
│
├── scripts/                                   # Repo-side split by lifecycle / target user; all root_scripts/ + setups_scripts/ deploy to /root/vault/ on the VM
    ├── root_scripts/                          # Recurring scripts run by root nightly via cron
    │   ├── lib.sh                             # Shared constants + helpers (sourced; never executed)
    │   ├── main.sh                            # Orchestrator (the only script cron invokes)
    │   ├── backup.sh                          # tar → age-encrypt → minisign-sign → bundle → retention
    │   ├── docker-update.sh                   # Per-service podman image pulls (3× retry)
    │   ├── system-update.sh                   # apt update/upgrade/dist-upgrade/autoremove
    │   └── reboot.sh                          # Always reboots after safety gates pass
    ├── setups_scripts/                        # One-time installers run by root during VM rebuild + on version bumps
    │   ├── setup-age.sh                       # Pins age binaries (Linux + Windows) into /srv/tools/age/<ver>/
    │   └── setup-minisign.sh                  # Pins minisign binaries (Linux + Windows) into /srv/tools/minisign/<ver>/
    ├── poduser_scripts/                       # Deploys to poduser's home
    │   └── start-containers.sh                # @reboot cron target, waits for net+DNS, then podman-compose up -d
    └── truenas_scripts/                       # Runs on the TrueNAS host, not the VM
        └── truenas-script.sh                  # Pulls backups + logs from VM, then pushes to Hetzner Storage Box

```

---

## 🖥️ Infrastructure Setup

### **Proxmox VM with Dedicated NIC Binding**

The Vaultwarden service has been migrated from a Raspberry Pi to a **dedicated Debian 13 VM running on Proxmox**. This infrastructure change was implemented to enable **full system backups** while maintaining strict network isolation.

#### **VM Configuration**
* Runs a clean **Debian 13** installation
* Assigned to a **dedicated physical NIC** on the Proxmox host (one of two available NICs)
* The physical network cable for this NIC is connected to a switch port assigned to the **VLAN-DMZ** VLAN group
* This setup preserves the original VLAN isolation baseline while providing VM stability and backup capabilities

#### **Benefits of This Migration**
* **Full system backups**: The VM-based approach enables complete system snapshots, ensuring full recovery capability beyond just data backups
* **Hardware independence**: Decouples Vaultwarden from bare-metal hardware constraints and provides more flexibility for maintenance and scaling
* **Proxmox integration**: Leverages Proxmox's management tools, monitoring, and resource controls
* **Network isolation preserved**: Despite the migration, the dedicated NIC binding ensures the VM remains isolated on VLAN-DMZ with the same strict firewall rules applied

#### **Host Tuning**

The QUIC UDP receive buffer must be increased on the VM for cloudflared tunnel performance. Without this, cloudflared logs a warning about insufficient buffer size and QUIC connections may drop packets under load. See [quic-go UDP Buffer Sizes](https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes) for details.

```bash
sysctl -w net.core.rmem_max=7500000
sysctl -w net.core.wmem_max=7500000

# Persist across reboots
echo "net.core.rmem_max=7500000" | tee -a /etc/sysctl.d/99-udp-buffer.conf
echo "net.core.wmem_max=7500000" | tee -a /etc/sysctl.d/99-udp-buffer.conf
```

This is a host-level kernel setting, it applies to all containers running on the VM.

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

Defines the core variables for the setup. A template is provided at `.env.template`. Variables are grouped by domain:

```bash
# --- Infra ---
TZ=''
SERVER_NAME=''                 # The hostname/SNI served (e.g. vault.example.com)

# --- ACME / Cloudflare ---
EMAIL_LETS_ENCRYPT=''          # Used as the ACME contact email
CLOUDFLARE_API_TOKEN=''        # Scoped Cloudflare token for DNS-01 challenges
CLOUD_TOKEN=''                 # cloudflared tunnel token

# --- CrowdSec ---
CROWDSEC_BOUNCER_KEY=''        # API key shared between CrowdSec LAPI and BunkerWeb's bouncer plugin (generate with `openssl rand -base64 48`)
CROWDSEC_ENROLL_KEY=''         # Console-enrollment key for app.crowdsec.net (one-time)

# --- Vaultwarden ---
ADMIN_TOKEN=''                 # Admin panel token (Argon2 hash; generate inside the container)
DOMAIN=''                      # Public URL Vaultwarden advertises (e.g., https://vault.example.com)

# --- SMTP ---
SMTP_HOST=''
SMTP_PORT=''
SMTP_SECURITY=''               # starttls / ssl
SMTP_USERNAME=''
SMTP_PASSWORD=''
SMTP_FROM=''
SMTP_FROM_NAME=''
SMTP_TIMEOUT=''
```

I personally use [Mailjet](https://www.mailjet.com) for SMTP.

---

### **Two Compose Flavors**

Two `docker-compose.*.yml` files are provided. They are **mutually exclusive**, only one runs at a time, both define the same service / volume / network names so a switchover is non-destructive:

| File | Public exposure | ACME challenge | Use when |
|------|-----------------|----------------|----------|
| **`docker-compose.dns-challenge.yml`** | Cloudflare Tunnel (no host ports) | DNS-01 via Cloudflare API token | Production. Outbound-only firewall, hidden origin IP, edge filtering at Cloudflare. |
| **`docker-compose.http-challenge.yml`** | Direct host ports 80/443 (TCP+UDP) | HTTP-01 | Direct exposure (no Cloudflare in front). Simpler setup; origin IP is public. |

Both flavors run the same four services: `bunkerweb` (proxy/WAF), `crowdsec` (LAPI + parsers), `vaultwarden`, and, in the dns-challenge flavor only, `cloudflared` (tunnel client).

#### **Network segmentation (dns-challenge flavor)**

The dns-challenge flavor splits services across three Podman bridge networks with pinned subnets:

| Network | Subnet | Members | Purpose |
|---------|--------|---------|---------|
| `tunnel` | `10.89.0.0/24` | `cloudflared` ↔ `bunkerweb` | Edge ingress |
| `security` | `10.89.1.0/24` | `bunkerweb` ↔ `crowdsec` | Bouncer ↔ LAPI |
| `backend` | `10.89.2.0/24` | `bunkerweb` ↔ `vaultwarden` | Reverse-proxy upstream |

`cloudflared` cannot reach `vaultwarden` directly; `crowdsec` cannot reach `vaultwarden`; `vaultwarden` cannot reach `cloudflared` or `crowdsec`. Defense in depth, a compromise of any single container has limited blast radius.

Subnets are pinned in the compose file so the aardvark-dns gateway IPs (`10.89.0.1`, `10.89.1.1`, `10.89.2.1`) referenced in `DNS_RESOLVERS` stay contractual across `down`/`up` cycles.

---

### **Container runtime**

* **Podman** runs all containers, rootless, under the dedicated `poduser` account.
* **`podman-compose`** handles compose-file orchestration: parsing (`config --services` to enumerate services in `docker-update.sh`), `up`/`down`/`restart` for lifecycle, and image pulls.
* For interactive use, drop into a poduser login shell first (`sudo su - poduser`) then run `podman-compose ...` directly. The maintenance scripts use the non-interactive `sudo -u poduser podman-compose ...` form because they can't open a shell from within a script.
* `poduser` has **no sudo privileges** and is not in any privileged group, so the only way to touch containers is through root user-switching. Clean privilege boundary between the orchestrator (root scripts) and the runtime (poduser).
* No docker daemon installed on this VM. Earlier Ubuntu-based versions of this stack kept docker installed only because `podman-compose config --services` produced noisy header output on older podman; the Debian 13 + podman 5.x combination outputs cleanly and docker is no longer a dependency. (The PiHole VM, on Ubuntu Server, still uses `docker compose` because that's what its scripts were written against, separate stack, separate decision.)

---

## 🛡️ BunkerWeb Reverse Proxy + WAF

[BunkerWeb](https://www.bunkerweb.io/) is an nginx-based all-in-one reverse proxy that bundles ACME, security headers, country/UA blacklists, rate limiting, ModSecurity (CRS), and CrowdSec bouncer plugins behind a single configuration surface. It replaces the previous Caddy + Certbot + Cloudflare Worker bouncer combination.

The image used in both compose flavors is the **`bunkerity/bunkerweb-all-in-one`** flavor (single container; no separate scheduler/UI/db).

### **Built-in features used**

| Feature | Configuration | What it does |
|---------|---------------|--------------|
| **ACME** | `AUTO_LETS_ENCRYPT: yes`, `LETS_ENCRYPT_CHALLENGE: dns` (or `http`), `LETS_ENCRYPT_DNS_PROVIDER: cloudflare` | Issues + renews Let's Encrypt certs. DNS-01 in the dns-challenge flavor; HTTP-01 in the http-challenge flavor. |
| **Reverse proxy** | `USE_REVERSE_PROXY: yes`, `REVERSE_PROXY_HOST: http://vaultwarden:8080`, `REVERSE_PROXY_WS: yes` | Proxies all traffic to Vaultwarden. WS support is required for `/notifications/hub`. |
| **TLS hardening** | `SSL_PROTOCOLS: TLSv1.3`, `SSL_CIPHERS_LEVEL: modern` | TLS 1.3 only; modern cipher suite. |
| **Real client IP** | `USE_REAL_IP: yes`, `REAL_IP_HEADER: CF-Connecting-IP`, `REAL_IP_FROM: 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16` | dns-challenge: trusts Cloudflare's `CF-Connecting-IP` from the `cloudflared` hop. |
| **Country blacklist** | `BLACKLIST_COUNTRY: CN RU KP IR SY CU VE BY` | Geo-blocks at the proxy. |
| **UA blacklist** | `BLACKLIST_USER_AGENT: python-requests python-urllib python-httpx httpx wget go-http-client libwww-perl masscan` (plus BW's own auto-fetched list) | Blocks scripted clients and known bad UAs. |
| **DNSBL** | `USE_DNSBL: yes`, `DNSBL_LIST: bl.blocklist.de dnsbl.dronebl.org` | Checks source IPs against public abuse lists. |
| **Rate limit** | `USE_LIMIT_REQ: yes`, `LIMIT_REQ_RATE: 5r/s`, `LIMIT_REQ_BURST: 15` | Per-IP nginx-level throttle. Burst of 15 absorbs parallel asset fetches on normal page loads. |
| **bad_behavior** | `USE_BAD_BEHAVIOR: no` | **Disabled**, naive non-200 counter false-positives on Vaultwarden's `/admin/diagnostics`. CrowdSec's scenario-based detection covers this surface instead. |
| **ModSecurity / CRS** | `USE_MODSECURITY: yes`, `USE_MODSECURITY_CRS: yes`, `MODSECURITY_SEC_RULE_ENGINE: DetectionOnly` | Engine is in **DetectionOnly**, every rule match is written to `modsec_audit.log` but **nothing is blocked**. Tuning + exclusions are still being written; the engine flips to `On` only once the audit log is clean on legitimate traffic. Full detail in the [ModSecurity / OWASP CRS section](#-modsecurity--owasp-crs-detection-only--work-in-progress). |
| **CrowdSec bouncer** | `USE_CROWDSEC: yes`, `CROWDSEC_API: http://crowdsec:8080`, `CROWDSEC_MODE: stream`, `CROWDSEC_UPDATE_FREQUENCY: 15` | Polls CrowdSec LAPI every 15s for the active decisions list; enforces bans inline (returns 403). |
| **Server header suppression** | `REMOVE_HEADERS: Server Via X-Powered-By X-AspNet-Version X-AspNetMvc-Version` | Removes server-identification headers. |
| **Error-body passthrough** | `INTERCEPTED_ERROR_CODES: ""` | Empty override, BW does NOT replace upstream 4xx/5xx responses with branded HTML pages. Required so Vaultwarden's API JSON error bodies pass through to Bitwarden clients. |
| **Allowed HTTP methods** | `ALLOWED_METHODS: "GET\|POST\|HEAD\|PUT\|PATCH\|DELETE\|OPTIONS"` | Override BW's default (`GET\|POST\|HEAD`). Vaultwarden's API uses PUT (cipher edit + soft-delete to trash via `/api/ciphers/<id>/delete`), PATCH, DELETE, and OPTIONS (CORS preflight from web vault + browser extensions). Without this override, every vault edit 405s at the nginx layer before ModSec or Vaultwarden ever sees the request. Pipe-separated (regex alternation, not commas/spaces). |

### **Custom configs (`bunkerweb/custom-configs/`)**

Mounted at `/data/configs/` inside the container, BunkerWeb's native ingest path. The scheduler scans `/data/configs/<type>/`, writes into its DB, and renders to `/etc/bunkerweb/configs/` (which is internal and writable). Mount is `rw` (not `ro`) because BW's entrypoint creates per-type subdirs on boot.

| File | Type / scope | Purpose |
|------|--------------|---------|
| `server-http/headers-passthrough-apply.conf` | server-http | **Owns all outbound security headers** (HSTS, COOP, Referrer-Policy, Permissions-Policy, X-Content-Type-Options) using `more_set_headers`. Bypasses BW's env-var headers plugin to insulate against version-to-version drift in BW's emission rules. |
| `http/headers-upstream-passthrough.conf` | http | http-scope `map` directives that capture Vaultwarden's `X-Frame-Options` and `Content-Security-Policy` from upstream so the apply file can pass them through (preserving Vaultwarden's per-endpoint control, e.g., the Duo iframe on `/2fa-connector.html`). |
| `server-http/security-txt-lang.conf` | server-http | nginx `location` blocks for `/.well-known/security.txt` and `/robots.txt`; redirects `/security.txt` to the canonical path; re-applies headers (nginx `add_header` in a `location` replaces parent headers, so they must be repeated). |

ModSecurity-specific custom configs (`modsec-crs/paranoia.conf`, `modsec-crs/exclusions-before-crs.conf`, `modsec/exclusions-after-crs.conf`) are documented in the dedicated [ModSecurity / OWASP CRS section](#-modsecurity--owasp-crs-detection-only--work-in-progress) below.

---

## 🧪 ModSecurity / OWASP CRS (detection-only, work in progress)

> **Current state: nothing is being blocked by the WAF.** The engine is set to `MODSECURITY_SEC_RULE_ENGINE: DetectionOnly` in the compose file, so every rule match is written to `/srv/bw-logs/modsec_audit.log` but the request is **not** rejected. This is intentional, exclusions for Vaultwarden's API are still being built up, and flipping to blocking before the audit log is clean would break the clients (vault edits, attachments, sync, sends, admin panel).
>
> The engine will flip to `On` only after the audit log is consistently quiet on legitimate traffic. Until then, treat the WAF as a **logging-only tripwire**, not an active defence, blocking on this stack today is done by CrowdSec (scenario-driven IP bans) and BunkerWeb's other plugins (country / UA / DNSBL / rate limit), not by ModSecurity.

### Configuration files

Three custom configs in `bunkerweb/custom-configs/` carry the CRS tuning:

| File | Type / scope | Purpose |
|------|--------------|---------|
| `modsec-crs/paranoia.conf` | modsec-crs | Sets CRS's `tx.detection_paranoia_level` and `tx.blocking_paranoia_level`. Detection at **PL2**, blocking at **PL1** to start. `blocking_paranoia_level` gets bumped to PL2 once exclusions are stable at PL2 detection. |
| `modsec-crs/exclusions-before-crs.conf` | modsec-crs (phase 1) | **Preferred location** for request-side exclusions (rule IDs <950). Sets `tx.allowed_methods` to include PUT/PATCH/DELETE; a layered fallback at the ModSec layer. The actual upstream method gate is BunkerWeb's own `ALLOWED_METHODS` env-var (set in compose); this exclusion ensures that once `MODSECURITY_SEC_RULE_ENGINE` flips from `DetectionOnly` to `On`, CRS rule 911100 doesn't re-introduce a block on Vaultwarden's PUT/PATCH/DELETE traffic. |
| `modsec/exclusions-after-crs.conf` | modsec (phase 3) | Response-side exclusions (rule IDs 95x / 98x). Files ship with commented templates for the common Vaultwarden false positives, uncomment them only after the matching rule actually fires in `modsec_audit.log`. |

### Tuning workflow

1. Exercise real traffic against the stack (login, vault edit, attachment upload, send create, admin panel browse, etc.).
2. Tail `/srv/bw-logs/modsec_audit.log` and look for entries logging rule matches against legitimate requests. Capture the rule ID.
3. Add (or uncomment) an exclusion in the matching phase file:
    * Request-side rule (rule ID <950) → `exclusions-before-crs.conf`
    * Response-side rule (rule ID 95x / 98x) → `exclusions-after-crs.conf`
4. Restart the proxy:
    ```bash
    podman-compose -f docker-compose.dns-challenge.yml restart bunkerweb
    ```
5. Repeat the action that triggered the false positive. Confirm the rule no longer fires.
6. Once `modsec_audit.log` is consistently clean for ≥1 week of normal use, flip `MODSECURITY_SEC_RULE_ENGINE` from `DetectionOnly` to `On` in the compose file. Then bump `blocking_paranoia_level` from PL1 to PL2 in `paranoia.conf`.

### Known exclusions list

This section will grow as false positives are identified and exclusions land. Each entry should explain **what triggered it**, **what client behaviour the rule mistook for an attack**, and **the rule ID + phase**.

| Rule ID | Phase | Trigger | Reason kept |
|---------|-------|---------|-------------|
| 911100 | 1 (request) | Vaultwarden API uses `PUT` / `PATCH` / `DELETE` for vault edits and item deletes; CRS default `tx.allowed_methods` is `GET HEAD POST OPTIONS`. | Preemptive: BW's `ALLOWED_METHODS` plugin is today's upstream method gate (set in compose, returns 405 if violated). This ModSec-layer exclusion ensures that once the engine flips from `DetectionOnly` to `On`, rule 911100 doesn't re-introduce a 403 block on PUT/PATCH/DELETE. |
| 942120 | 2 (request body) | Base64 padding `==` in encrypted cipher fields (`ARGS:json.login.password`, `json.login.username`, `json.login.fido2Credentials.*.counter`, etc.) on `POST/PUT /api/ciphers[/<uuid>]` is matched as a SQL operator. | Verified from `modsec_audit.log` (7 hits / 4 days). Without this, every cipher add/edit emits an `SQL Injection Attack: SQL Operator Detected` warning. Scoped narrowly to `/api/ciphers`. |
| 942430 | 2 (request body) | JWT `access_token` query arg on `/notifications/hub` (Bitwarden WebSocket live-sync) contains many `.`, `-`, `_`, `=` chars, exceeding the rule's 12-special-character threshold. | Verified from `modsec_audit.log` (10 hits / 4 days). Fires on every client connect/refresh. Scoped to `/notifications/hub`. |
| 932240 | 2 (request body) | Argon2id-hashed admin_token (`$argon2id$v=19$m=...$<base64>$<base64>`) trips the rule's digit/quote/digit pattern on `POST /admin/config`. | Verified from `modsec_audit.log` (4 hits / 4 days). Scoped narrowly to `/admin/config`; other 932xxx RCE rules still apply on the same endpoint. |
| 953101 | 4 (response body) | Vaultwarden's English `/locales/<lang>/messages.json` legitimately contains the literal phrase "file size is" in i18n error messages, which 953101 looks for as a PHP error-string signature. | Verified from `modsec_audit.log` (4 hits / 4 days). Vaultwarden is Rust, not PHP, so the rule is structurally an FP for this app. Scoped to `/locales/`. Lives in `exclusions-after-crs.conf`. |
| _(more to come)_ | | | |

### When the audit log is too noisy

If too many rules fire to triage one at a time, the right move is **not** to mass-disable rules, drop the detection paranoia level temporarily (`tx.detection_paranoia_level` from PL2 to PL1 in `paranoia.conf`), get blocking running clean at PL1 first, then raise detection back to PL2 and work through the next batch. Permanent disables go in the exclusion files with a comment explaining why.

---

## 🛡️ CrowdSec Integration

CrowdSec is integrated to provide active protection against brute-force, enumeration, and probing attacks by **automatically banning malicious IPs**. Vaultwarden writes structured logs to `/srv/vw-logs/vaultwarden.log` using extended logging; BunkerWeb writes access/error/modsec_audit logs to `/srv/bw-logs/`. CrowdSec parses both in real time via the parsers we ship in `crowdsec/parsers/` plus its own hub-installed parsers.

This setup builds on the [Vaultwarden collection by Dominic-Wagner](https://app.crowdsec.net/hub/author/Dominic-Wagner/collections/vaultwarden), with our own parser/scenario customizations and a custom whitelist for Vaultwarden's `/admin/diagnostics` page.

**References**:
- [Dominic-Wagner's Vaultwarden Collection](https://app.crowdsec.net/hub/author/Dominic-Wagner/collections/vaultwarden)
- [BunkerWeb CrowdSec plugin docs](https://docs.bunkerweb.io/) (proxy-side bouncer)
- [Dominic-Wagner on GitHub](https://github.com/Dominic-Wagner)

### **Vaultwarden Logging Configuration**

Vaultwarden is configured in the compose file with:

* `/srv/vw-logs:/logs` as the dedicated log volume
* `EXTENDED_LOGGING=true`, `LOG_LEVEL=error`, and a consistent timestamp format (`%Y-%m-%d %H:%M:%S.%3f%z`)
* Custom rate limits designed to complement CrowdSec, three independent layers:

```bash
# Most strict, admin token bruteforce
ADMIN_RATELIMIT_MAX_BURST=10
ADMIN_RATELIMIT_SECONDS=300

# Tightened from VW default (10/60s), master-password attempts
LOGIN_RATELIMIT_MAX_BURST=3
LOGIN_RATELIMIT_SECONDS=60

# Generous, general API
RATELIMIT_MAX_BURST=100
RATELIMIT_SECONDS=60
```

This stack-orders the throttles from cheapest to most-targeted. CrowdSec then evaluates the resulting log lines against scenarios with longer-window logic and issues real bans on top of these per-request throttles.

### **Containerized CrowdSec**

CrowdSec runs as its own container alongside BunkerWeb (replaces the previous host-installed setup). Two named volumes hold its persistent state:

* `crowdsec-db` → `/var/lib/crowdsec/data`, bouncer keys, console enrollment state, decisions database, community blocklist
* `crowdsec-config` → `/etc/crowdsec`, hub-installed collections + auto-generated config files

Three bind mounts deliver our custom config into the right CrowdSec stages:

* `./crowdsec/parsers:/etc/crowdsec/parsers/s01-parse/vaultwarden:ro`
* `./crowdsec/scenarios:/etc/crowdsec/scenarios/vaultwarden:ro`
* `./crowdsec/whitelists:/etc/crowdsec/parsers/s02-enrich/vaultwarden:ro`

Each mounts into a `vaultwarden/` subdir so the hub can keep ownership of the parent dir for its own symlinks. The acquisition files (`crowdsec/acquis.d/*.yaml`) are mounted **per-file** for the same reason, overlaying the whole `acquis.d` directory `:ro` would block CrowdSec from writing sibling files (e.g., from auto-installed acquisitions).

### **Custom Parsers, Scenarios, and Whitelists**

#### **Parser**, `crowdsec/parsers/vaultwarden-logs.yaml`

Adapted from Dominic-Wagner's hub parser. Tags log events with `evt.Meta.log_type` values:

* `vaultwarden_failed_auth`, wrong master password
* `vaultwarden_failed_admin_auth`, wrong admin token
* `vaultwarden_failed_2fa_totp`, TOTP failure
* `vaultwarden_failed_2fa_email`, Email-2FA failure

#### **Scenarios**, `crowdsec/scenarios/vaultwarden-bf.yaml`

Two leaky-bucket scenarios, **tightened** from the hub defaults to suit a small homelab:

| Scenario | Filter | Capacity | Leakspeed | Blackhole | What it catches |
|----------|--------|----------|-----------|-----------|-----------------|
| `Dominic-Wagner/vaultwarden-bf` | All `vaultwarden_failed_*` log_types | 5 (was 20) | 5m (was 3m) | 4h | Repeated auth failures from one IP. ~6 attempts to overflow when paired with the 3/60s VW login throttle. |
| `Dominic-Wagner/vaultwarden-bf_user-enum` | `vaultwarden_failed_auth`, distinct usernames | 5 (was 20) | 30m | 4h | Multiple distinct emails from one IP, enumeration pattern. |

Legit user impact: 1–2 typos drains within minutes; never trips a ban.

#### **Whitelist**, `crowdsec/whitelists/admin-diagnostics.yaml`

Drops Vaultwarden's intentional `/admin/diagnostics/*` and `/admin/does-not-exist` 4xx probes before the `crowdsecurity/http-admin-interface-probing` scenario sees them. Without this, opening the admin diagnostics page once self-locks you with a 4h ban.

### **Bouncer**

CrowdSec bans are enforced at the **BunkerWeb proxy** via its built-in CrowdSec plugin (`USE_CROWDSEC: yes`, `CROWDSEC_API: http://crowdsec:8080`, `CROWDSEC_MODE: stream`, `CROWDSEC_UPDATE_FREQUENCY: 15`). The plugin polls CrowdSec's LAPI every 15 seconds for the active decisions list and returns `403 Forbidden` to any matching IP at the nginx level, before the request reaches Vaultwarden.

This replaces the previous Cloudflare Workers bouncer (which enforced bans at Cloudflare's edge). The trade-off: bans now happen one hop later (at the proxy, not at the edge), but the architecture works identically with or without Cloudflare in front, and there's no extra Worker to maintain or pay for.

---

## 🌐 Cloudflare Tunnel

(Used in the **dns-challenge flavor only**.)

The `cloudflared` container establishes an outbound-initiated tunnel to Cloudflare's edge, registered with the `CLOUD_TOKEN` from the dashboard. All inbound traffic for the public hostname (`SERVER_NAME`) arrives via this tunnel, there are **no host ports exposed** on the VM.

* **Hidden origin IP**, the VM's public IP is never advertised in DNS or seen by clients
* **No inbound firewall rules required**, the tunnel is initiated outbound by `cloudflared`
* **DDoS absorption at Cloudflare**, attacks hit the edge, not the home network
* **Real client IP forwarded as `CF-Connecting-IP`**, BunkerWeb's `USE_REAL_IP` + `REAL_IP_HEADER` config trusts this and rewrites nginx's `$remote_addr` so logs and CrowdSec see actual visitor IPs

Limits: cloudflared adds latency (~50–100ms tunnel hop) and an extra failure dependency (Cloudflare service health). For a personal vault accessed by ~5 users, both are acceptable.

---

## 🔄 Automation Scripts

Repo-side, the scripts are split by lifecycle and target user. On the VM, **`root_scripts/` and `setups_scripts/` both deploy to `/root/vault/`** (root-owned, mode 700), the repo split is purely organizational. `poduser_scripts/` deploys to `poduser`'s home; `truenas_scripts/` runs on the TrueNAS host.

### **Recurring (root, nightly via cron)**

| Script | Purpose |
|--------|---------|
| **`main.sh`** | Orchestrator. The **only script cron invokes**. Acquires a flock to prevent overlapping runs, then calls each phase in order and narrates failures with `explain_exit_code`. Final `STATUS:` line summarises what succeeded. |
| **`backup.sh`** | (1) Stops containers via `podman-compose down` (sqlite must be at rest before tar) → (2) `tar /srv/vw-data` → (3) age-encrypt with the recipient public key → (4) minisign-sign the encrypted archive → (5) bundles encrypted archive + age binaries (Linux+Windows) + minisign binaries (Linux+Windows) + manifest + DECRYPT.txt → (6) cleans intermediates → (7) 30-day retention. **Failure aborts the whole orchestrator run**, no point updating a host whose data couldn't be captured. Exit codes 10–14. |
| **`docker-update.sh`** | Per-service podman image pulls with 3× retry, removes obsolete image IDs. Pull failures are logged but **non-fatal** (exit 0 so orchestrator continues). Exit code 20 only on compose-dir / stop-containers failure. |
| **`system-update.sh`** | `apt-get update / upgrade / dist-upgrade / autoremove`, ensures `unattended-upgrades` is installed + enabled, preserves `sshd_config` via `UCF_FORCE_CONFFOLD=1` on openssh-server upgrades (unattended reconfig could lock us out of the VM). Failures log-and-continue. Exit codes 30–33. |
| **`reboot.sh`** | **Always reboots** after safety gates pass (containers stopped + apt/dpkg lock free). The Debian `/var/run/reboot-required` flag misses reasons like "container image was updated", so the cycle unconditionally reboots instead. Exit code 40 if a safety gate blocks the reboot. |
| **`lib.sh`** | Shared library. Sourced by every phase script; never executed. Defines all readonly paths (auto-derived from where lib.sh sits), the `EXIT_CODE_DESC` associative array (single source of truth for non-zero codes), and helpers (`log`, `fail`, `warn`, `require_root`, `require_cmd`, `stop_containers`, `verify_age_prereqs`, `verify_minisign_prereqs`, `deadman_ping`, `explain_exit_code`). |

### **One-time (root, during VM rebuild + version bumps)**

| Script | Purpose |
|--------|---------|
| **`setup-age.sh`** | Pins [age](https://github.com/FiloSottile/age) binaries (Linux + Windows) from GitHub releases into `/srv/tools/age/<version>/`. `lib.sh` references the pinned path via `AGE_VERSION`. After running, bump the constant to activate. |
| **`setup-minisign.sh`** | Mirror of `setup-age.sh` for [minisign](https://github.com/jedisct1/minisign). Pins binaries into `/srv/tools/minisign/<version>/`. `lib.sh` references via `MINISIGN_VERSION`. |

**Note:** neither `age` nor `minisign` is added to `PATH`, callers must use the full `${AGE_BINARY}` / `${MINISIGN_BINARY}` paths (which `lib.sh` builds from `AGE_VERSION` / `MINISIGN_VERSION`). All scripts in `root_scripts/` already do this; humans running either tool by hand need to remember (e.g., `/srv/tools/age/v1.3.1/age -d ...`, `/srv/tools/minisign/0.12/minisign -V ...`).

Upstream signature verification of these downloads is **not yet implemented**, see `ideas.md` #8 for the planned approach (`gh attestation verify` is the leaning option).

### **Boot (poduser, via @reboot)**

| Script | Purpose |
|--------|---------|
| **`start-containers.sh`** | poduser's `@reboot` cron target. Waits for a default route + DNS resolution, then runs `podman-compose up -d --force-recreate`. Not called by `main.sh`; only by the poduser crontab. This is how containers come back up after the reboot triggered by `reboot.sh`. |

### **Off-site replication (TrueNAS, via cron)**

| Script | Purpose |
|--------|---------|
| **`truenas-script.sh`** | Runs on TrueNAS (not the VM). Pulls daily encrypted bundles + all four phase logs from the VM via `scp`, then pushes a copy to the **Hetzner Storage Box** via rclone. Local backups on TrueNAS + cloud backups on Hetzner. |

**Why a dedicated `fetcher` user on the VM (and not just root):** the scp source is a purpose-built unprivileged account called `fetcher`. The backup bundle directory (`/srv/backups/`) and the four phase-log directories (`/srv/logs/{main,backup,docker,system}/`) have their ownership / group set so `fetcher` can read exactly those paths, nothing else on the VM is reachable to that user. Credential hardening mirrors the [`poduser`](#-container-startup-and-podman-user-configuration) pattern:

- **Not in the `sudo` group**, even with the SSH key, `fetcher` cannot escalate. No root-level commands, no service control, no package install.
- **SSH key auth only, passwords disabled at the daemon level.** `sshd_config` enforces `PasswordAuthentication no` globally, so the fact that `fetcher` happens to have a password set in `/etc/shadow` is irrelevant for SSH (no password prompt is ever offered). `fetcher` is also explicitly listed under `AllowUsers` in sshd, so the daemon doesn't reject the connection on principle. The matching private key (`/root/.ssh/fetcher_automation_rsa`) lives on TrueNAS, root-readable only.
- **Read-only on the data it serves**, `fetcher` can read `/srv/backups/` and `/srv/logs/`, but cannot write to them, modify them, or reach `/srv/vw-data/`, `/srv/vw-logs/`, the compose files, or anything under `/root/`.
- **Standard `/bin/bash` shell.** Deliberate, not a gap. Forcing `/usr/sbin/nologin` would break scp under some sshd configurations and gain nothing meaningful, the lockdown is at the SSH daemon (no password auth + AllowUsers gating) and at the filesystem (no sudo + read-only data scope), not at the shell.

So if the TrueNAS-side private key is ever stolen, the blast radius is "an attacker can pull the same encrypted bundles + logs the legitimate process pulls." They get nothing they couldn't already get by stealing the bundles directly off TrueNAS or Hetzner, and crucially, they cannot use the foothold to pivot anywhere else on the Vaultwarden VM.

### **Policy summary**

* **Backup failure aborts the whole nightly run**, no point updating a host you couldn't snapshot
* **Image-update + system-update failures log-and-continue**, retry tomorrow
* **Reboot is unconditional** if both safety gates pass (containers stopped + apt/dpkg lock free)
* The `STATUS:` line at the end of each `main.sh` run summarises what succeeded (`OK` / `DOCKER_UPDATE_FAILED_BACKUP_OK` / etc.)
* Logs land at `/srv/logs/{main,backup,docker,system}/` with 30-day retention

Only `main.sh` goes in cron, never schedule phase scripts independently. They depend on the orchestrator's locking and ordering.

---

## 🧱 DMZ Firewall Rules

The Vaultwarden service is isolated on its **own VLAN (VLAN-DMZ)** behind strict ingress and egress rules to ensure only **essential traffic** is allowed, minimizing the attack surface.

| # | Action | Protocol  | Source     | Destination                                                                                 | Port     | Description                        | Log |
|---|--------|-----------|-----------|---------------------------------------------------------------------------------------------|----------|-------------------------------------|-----|
| 1 | Pass   | TCP       | VLAN-DMZ  | 192.168.173.9 (`proxy-home` VM, Squid)                                                     | 3128     | Allow HTTP/HTTPS egress via Squid  | Yes |
| 2 | Pass   | TCP/UDP   | VLAN-DMZ  | 192.168.173.2 (LAN Pi-hole VM)                                                              | 53       | Allow DNS via Pi-hole              | Yes |
| 3 | Block  | Any       | VLAN-DMZ  | (Any other VLANs)                                                                           | Any      | Block DMZ to other VLANs           | Yes |
| 4 | Pass   | UDP       | VLAN-DMZ  | This Firewall                                                                              | 123      | Allow NTP                          | Yes |
| 5 | Pass   | UDP       | VLAN-DMZ  | [Cloudflare_IPs](https://www.cloudflare.com/ips/)                                          | 7844 | Allow QUIC from Cloudflare         | Yes |
| 6 | Pass   | TCP       | VLAN-DMZ  | Mailjet_SMTP (`in-v3.mailjet.com`)                                                          | 587      | Allow SMTP                         | Yes |

Rules 1 and 2 are the two outbound chokepoints. Rule 1 points at the `proxy-home` VM (Squid for HTTP/HTTPS); rule 2 points at the homelab's LAN Pi-hole (DNS, with logging shipped into Wazuh, see [Outbound DNS via the LAN Pi-hole + Wazuh visibility](#-outbound-dns-via-the-lan-pi-hole--wazuh-visibility)). Both allows sit **above** the catch-all VLAN block (rule 3), so DMZ → chokepoint traffic is permitted before the catch-all denies everything else cross-VLAN.

📄 **References**:
- `proxy-home/vault_domains_allow_proxy.txt` contains all domain allowlists configured in the Squid proxy
- [Cloudflare IP Ranges](https://www.cloudflare.com/ips/) are used to allow QUIC traffic

> **Note on Rule 5 (QUIC):** Cloudflare publishes their IP ranges as a single aggregated list covering all of their services, they do not provide separate ranges per product (e.g., Tunnels, CDN, Workers). Because of this, the firewall rule must allow the entire [Cloudflare IP list](https://www.cloudflare.com/ips/) on UDP port 7844 so the `cloudflared` tunnel can be established. While this is broader than ideal, the rule is scoped to a single port (QUIC 7844) and only permits outbound UDP from the DMZ, limiting the effective exposure.

---

## 🌐 Outbound HTTP/HTTPS proxy, Squid on the `proxy-home` VM

> The Vaultwarden VM has **two outbound chokepoints** on different VMs:
> - **HTTP/HTTPS** → Squid on the `proxy-home` VM, `192.168.173.9:3128` (this section)
> - **DNS** → the homelab's LAN Pi-hole, `192.168.173.2:53` ([next section](#-outbound-dns-via-the-lan-pi-hole--wazuh-visibility))
>
> The Vault VM doesn't reach the public internet directly for either protocol. HTTP/HTTPS goes through Squid's domain allowlist; DNS goes through Pi-hole, which logs every query, ships the log to Wazuh, and forwards upstream over DoH to Cloudflare Family. Each chokepoint is configured independently.
>
> One important nuance: when an app on the Vault VM uses the system's `http_proxy` env vars (apt, etc.), **Squid does the DNS lookup**, not the Vault VM. So those specific queries don't appear in Pi-hole's Vault-VM-scoped stream; Squid's allowlist is the gate for that path. The split between what each layer covers is documented in detail under [Which DNS queries Pi-hole actually sees from the Vault VM](#which-dns-queries-pi-hole-actually-sees-from-the-vault-vm).

Previously, domain access was restricted using firewall rules with domain allowlisting, but this approach was not reliable. I replaced it with a **dedicated Squid proxy** running in a separate VM on the Proxmox server.

### **Proxy Architecture**

* The Squid proxy VM is on a **different VLAN** than the Vaultwarden VM
* The Vaultwarden VM communicates through Squid (`192.168.173.9:3128`) for outbound traffic
* Domain allowlisting is managed via `proxy-home/vault_domains_allow_proxy.txt` and enforced by `proxy-home/squid.conf`
* `proxy-home/squid.conf` implements a **whitelist-only** approach: allows access to listed domains, blocks everything else

The allowlist covers Debian apt + container registries + Cloudflare + GitHub (for binary pinning) + BunkerWeb's blacklist feeds + DB-IP (country MMDB) + CrowdSec's hub & community blocklist + `icons.bitwarden.net` (Vaultwarden's icon redirect target) + Mailjet SMTP + Wazuh agent feeds. See `proxy-home/vault_domains_allow_proxy.txt` for the canonical list with rationale per entry.

### **System-Wide Proxy Configuration**

To route all outbound traffic through the Squid proxy, four configuration files must be created/edited on the VM. Each serves a specific purpose to ensure proxy variables are available in different contexts:

#### **1. `/etc/environment`**
Sets proxy variables for the entire system so all programs launched normally inherit them. Applies to both root and regular users, but **not** to systemd services.

```bash
http_proxy="http://192.168.173.9:3128"
https_proxy="http://192.168.173.9:3128"
HTTP_PROXY="http://192.168.173.9:3128"
HTTPS_PROXY="http://192.168.173.9:3128"
NO_PROXY="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
no_proxy="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
```

#### **2. `/etc/systemd/system.conf.d/proxy.conf`**
Systemd does not read `/etc/environment`, so this file forces all systemd services to inherit the proxy variables.

```ini
[Manager]
DefaultEnvironment="HTTP_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="http_proxy=http://192.168.173.9:3128"

DefaultEnvironment="HTTPS_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="https_proxy=http://192.168.173.9:3128"

DefaultEnvironment="NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
DefaultEnvironment="no_proxy=localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
```

#### **3. `/etc/profile.d/proxy.sh`**
Loads the proxy variables for interactive shells (SSH sessions). Ensures proxy variables exist when a user opens a shell and runs commands manually.

```bash
# System-wide proxy settings for interactive shells

export http_proxy="http://192.168.173.9:3128"
export https_proxy="http://192.168.173.9:3128"

export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

export no_proxy="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
export NO_PROXY="$no_proxy"
```

#### **4. Preserving Proxy Variables Through `sudo`**

When `main.sh` runs maintenance tasks, it uses `sudo -u poduser` to pull container images. This was failing with timeout errors because `sudo` strips environment variables by default, including the proxy configuration.

**Solution**: Configure `sudo` to preserve proxy variables by editing the sudoers file:

```bash
visudo
```

Add this line:

```text
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"
```

This ensures Podman receives the proxy configuration even when invoked through `sudo`, allowing image pulls to work correctly through the Squid proxy.

#### **Critical: `no_proxy` Configuration**

Container service names (`bunkerweb`, `crowdsec`, `vaultwarden`, `cloudflared`) plus `0.0.0.0`, `localhost`, and the loopback addresses are all in the `no_proxy` list. This ensures:

* Container-to-container traffic stays inside Podman's network, never goes to Squid
* CrowdSec's LAPI (binds to `0.0.0.0:8080`) is reached directly when its own clients (the bouncer plugin in BunkerWeb) talk to it, without `0.0.0.0` in `no_proxy`, those calls would be misdirected through Squid and DENIED
* DNS for service names is resolved by Podman's aardvark-dns, not by an upstream resolver via Squid

Without these entries, container startup would fail with cryptic Squid `407` / `403` errors.

---

## 🌐 Outbound DNS via the LAN Pi-hole + Wazuh visibility

> Second outbound chokepoint. Different VM than Squid: the Vault VM's `/etc/resolv.conf` points at the homelab's existing **LAN Pi-hole** (`192.168.173.2`) instead of running a dedicated DoH gateway purely for the Vault VM. The DoH-encrypted upstream is inherited from Pi-hole's existing `adguard/dnsproxy` sidecar (Cloudflare Family), and full visibility comes from a small sidecar daemon on the Pi-hole VM that tails Pi-hole's FTL SQLite database and ships one structured event per Vault-VM DNS query into Wazuh.

### Why Pi-hole instead of a dedicated dnsproxy

The earlier iteration ran `adguard/dnsproxy` directly on the `proxy-home` VM, with the Vault VM's `/etc/resolv.conf` pointing there. That worked, but had two costs: a second DoH stack to maintain just for one client, and DNS visibility limited to a `tail -f /srv/dnsproxy-logs/queries.log` on the proxy-home host (no SIEM integration at the time).

Reusing the existing LAN Pi-hole drops the duplicate stack and bolts the visibility piece directly onto Wazuh: every Vault VM query becomes an alert in the dashboard, scoped to the Vault VM's source IP, with full per-query metadata (qtype, query, status, blocked-or-not, upstream).

The same encrypted-upstream story is preserved: Pi-hole forwards to Cloudflare Family DoH via its own dnsproxy sidecar, so plaintext UDP never leaves the LAN.

### Why the FTL SQLite DB instead of Pi-hole's text log

Pi-hole's dnsmasq text log (`/var/log/pihole/pihole.log`) emits four-plus different syntactic patterns for "this query was blocked" depending on the source: `gravity blocked` (adlist), `exactly denied` (manual), `regex denied`, `blocked upstream with NULL address`, `reply X is blocked due to upstream response (answer)` followed by `<not set> X is 0.0.0.0`. Pi-hole versions reword these and add new flavors over time. Building a Wazuh decoder regex that catches every variant and stays correct across upgrades was whack-a-mole.

The FTL SQLite DB at `/etc/pihole/pihole-FTL.db` (host bind mount: `/home/pi/pihole/data/etc-pihole/pihole-FTL.db`) has a normalized **status** integer column that knows authoritatively what happened, regardless of how the dnsmasq text log phrased it. The sidecar reads it directly and emits one merged JSON event per query, with the block source as a stable enum (`blocked-gravity`, `blocked-deny-exact`, `blocked-upstream-null`, `blocked-external-null-reply`, ...) plus a single boolean `blocked` field for dashboard filtering.

### Architecture

```
[ Vaultwarden VM, 192.168.50.3 ]
  /etc/resolv.conf -> 192.168.173.2
            │
            │  UDP/53 (DMZ -> LAN; OPNsense pass rule 2)
            ▼
[ LAN Pi-hole VM, 192.168.173.2 ]
   ├─ pihole-FTL (dnsmasq)
   │     └─ writes /etc/pihole/pihole-FTL.db (SQLite; bind-mounted on the host as /home/pi/pihole/data/etc-pihole/pihole-FTL.db)
   ├─ adguard/dnsproxy (sidecar, DoH upstream to Cloudflare Family)
   ├─ pihole-ftl-tail.py (sidecar daemon, systemd-managed, polls FTL DB every 10s)
   │     filters to Vault VM client, emits JSON events
   │     -> /var/log/vault-dns/events.log
   └─ wazuh-agent
         │  tails /var/log/vault-dns/events.log (JSON)
         ▼
[ wazuh-home (Wazuh manager) ]
   ├─ built-in JSON decoder auto-extracts data.* fields
   ├─ rule 100250 (level 0): every Vault DNS event, archived
   ├─ rule 100251 (level 3): resolved query (forwarded / cached / etc)
   ├─ rule 100252 (level 6): Pi-hole's allowlist policy denied (gravity / regex / exact / CNAME variants)
   └─ rule 100253 (level 4): upstream returned non-answer (NULL / NXDOMAIN / NODATA, e.g. Cloudflare Family filtering or domain has no A record)
```

### What's where in this repo

The Pi-hole stack itself lives in [`PiHole/`](../PiHole/) at the root of this repo. Everything Wazuh-related (the sidecar daemon + manager-side rules + agent localfile snippet) lives in [`wazuh-home/`](./wazuh-home/), see its README for the architecture diagram, file mapping (which snippet goes on which VM), apply order, verification steps, and migration notes if you're upgrading from the previous text-log pipeline.

Quick summary of what's in `wazuh-home/`:

| File | Where it goes | What it does |
|------|---------------|--------------|
| `wazuh-home/sidecar/pihole-ftl-tail.py` | Install at **Pi-hole VM** `/usr/local/sbin/pihole-ftl-tail.py` | Daemon: polls Pi-hole's FTL SQLite DB, emits one JSON event per Vault VM query |
| `wazuh-home/sidecar/pihole-ftl-tail.service` | Install at **Pi-hole VM** `/etc/systemd/system/` | systemd unit (root, hardened, 10s polling tick) |
| `wazuh-home/pihole-agent.localfile.xml` | Append to `<ossec_config>` in **Pi-hole VM** `/var/ossec/etc/ossec.conf` | Tells the agent to tail the sidecar's `/var/log/vault-dns/events.log` (JSON format) |
| `wazuh-home/manager-global.snippet.xml` | One line inside `<global>` in **wazuh-home** `/var/ossec/etc/ossec.conf` | Enables `logall_json` so level-0 events land in `archives.json` (paired with `archives.enabled: true` in `/etc/filebeat/filebeat.yml` to also expose them as the `wazuh-archives-4.x-*` index in the dashboard) |
| `wazuh-home/manager-rules.xml` | Append inside **wazuh-home** `/var/ossec/etc/rules/local_rules.xml` | Four-rule chain: 100250 (archive base) + 100251 (resolved) + 100252 (Pi-hole policy block) + 100253 (upstream no-answer) |

### Which DNS queries Pi-hole actually sees from the Vault VM

The diagram above shows `/etc/resolv.conf -> 192.168.173.2`, but that's only half the story. The Vault VM uses **explicit proxy mode** for HTTP/HTTPS via Squid, which means a lot of name resolution doesn't happen on the Vault VM at all.

When something on the Vault VM uses the system's `http_proxy` / `https_proxy` env vars (apt, BunkerWeb's blacklist downloads, CrowdSec hub fetches, Vaultwarden's icon redirects, etc.), the actual DNS lookup is done by **Squid on `proxy-home`**, not by the Vault VM:

1. The app sends `CONNECT example.com:443 HTTP/1.1` (or `GET http://example.com/...` for plain HTTP) to Squid.
2. Squid receives the request, calls its own resolver to turn `example.com` into an IP, checks `example.com` against `vault_domains_allow_proxy.txt`, and either proxies the connection or returns 403.
3. The Vault VM never issued a DNS query for `example.com`. Pi-hole's per-Vault-VM allowlist never sees it.

So Pi-hole's strict allowlist for the Vault VM doesn't cover everything. It covers the queries the **Vault VM does itself**, which excludes anything proxied through Squid. The two layers are complementary, not redundant.

#### Coverage by egress path

| Egress path | DNS gate | Connection gate |
|---|---|---|
| HTTP/HTTPS via `http_proxy` (apt, app SDKs, etc.) | proxy-home's resolver, NOT Pi-hole-filtered for Vault VM | **Squid** allowlist |
| Direct UDP/QUIC (e.g. `cloudflared` to Cloudflare edge) | **Pi-hole** (Vault-VM group) | OPNsense rule 5 (UDP/7844 to Cloudflare IPs only) |
| Direct TCP outside Squid (e.g. SMTP to Mailjet `:587`) | **Pi-hole** (Vault-VM group) | OPNsense (specific allows; default-deny otherwise) |
| DNS itself (potential exfiltration channel) | **Pi-hole** (Vault-VM group) | n/a |
| Reverse DNS (`*.in-addr.arpa`, `*.ip6.arpa`) | **Pi-hole** (Vault-VM group) | n/a |

Each row has at least one chokepoint enforcing the allowlist. No single layer is solely responsible for any path.

A malicious process on the Vault VM trying to phone home:

- **Via HTTP/HTTPS proxy**: Squid's allowlist denies the CONNECT, even though proxy-home's DNS resolved the destination. The TCP connection to the C2 IP never opens.
- **Via raw TCP/UDP not through Squid**: Pi-hole's allowlist denies the DNS lookup, so the process can't get an IP. Even if it had a hardcoded IP, OPNsense default-denies the egress at L3/L4.
- **Via DNS-tunneling exfiltration** (encoding data in subdomain names): Pi-hole's allowlist denies the lookup. This is the failure mode Squid alone wouldn't catch, which is why Pi-hole's role isn't redundant.

#### proxy-home's own DNS, deliberately not strict

The `proxy-home` VM itself isn't subject to the Vault-VM strict allowlist. It's in Pi-hole's `Default` group and can resolve any domain. That's intentional: proxy-home only resolves domains it's about to proxy traffic to, and Squid's allowlist gates that traffic. proxy-home is essentially a "resolve + connect on behalf of Vault VM" service whose actual policy gate is Squid. If proxy-home itself is compromised the entire egress story falls apart, but that's a higher-trust component protected by its own Wazuh agent, FIM, and host hardening, not by adding more DNS-layer rules.

### Pi-hole groups + DNS-layer allowlist for the Vault VM

**Pi-hole acts as a strict allowlist enforcer for the Vault VM**, on top of also being the visibility layer. The Vault VM can resolve only domains explicitly allowlisted; every other lookup is denied at the DNS layer (returns `0.0.0.0`) and surfaces as a Wazuh alert. Other LAN clients are unaffected, this configuration carves out an isolated zone for the Vault VM only.

This is **defense-in-depth on top of Squid**. Squid (`proxy-home/squid.conf` + `vault_domains_allow_proxy.txt`) is the actual content gate for HTTP/HTTPS egress. The Pi-hole DNS allowlist gives a second enforcement layer, plus catches DNS-only reconnaissance (a compromised host resolving names to enumerate services without ever opening a connection). Both lists must stay in sync; see [`vault_domains_allow_dns.txt`](./vault_domains_allow_dns.txt) for the Pi-hole-format mirror of the Squid allowlist, and `ideas.md` for the planned single-source-of-truth automation.

`vault_domains_allow_dns.txt` is split into two sections: a **bulk** section of bare-domain exact-match entries (consumed by Pi-hole's "Add allowlist" URL feature) and an **apex** section listing regex entries for apex+subdomain matches that have to be added by hand. The apex section is necessary because Pi-hole 6's allowlist URL parser doesn't accept ABP syntax (`||apex^`), even though the same parser does accept it for blocklist URLs.

How to wire it in Pi-hole's web UI:

1. **Group Management → Groups**: create a `vaultwarden-vm` group.
2. **Group Management → Clients**: add the Vault VM's IP and assign it to that group, with **only** that group ticked (untick `Default`). Otherwise the Default group's adlists also apply and you'll see surprise blocks.
3. **Group Management → Adlists**: leave the `vaultwarden-vm` group with **no adlists ticked**. The Squid allowlist + this allowlist replace adlist filtering for this client.
4. **Lists → Add allowlist** (green button): paste the **raw GitHub URL** of the file as the address, scope to `vaultwarden-vm` group only:
   ```
   https://raw.githubusercontent.com/DiogoF-Hub/Homelab/main/Vaultwarden/vault_domains_allow_dns.txt
   ```
   Then **Tools → Update Gravity** to fetch and apply. Pi-hole parses the bare-domain lines as exact-match allows. Lines starting with `#` are comments and ignored; the regex lines in the "APEX (manual regex)" section at the bottom of the file are also `#`-prefixed so gravity skips them.
5. **Domain Management → Domains**: for each line in the **APEX section** at the bottom of `vault_domains_allow_dns.txt`, add an Allow Regex entry, scoped to `vaultwarden-vm` group only. There are 8 of them at time of writing (Let's Encrypt OCSP, Cloudflare R2, BunkerWeb apex, etc.), one-time setup.
6. **Domain Management → Domains**: add **one** Deny Regex entry, value `.*`, scoped to `vaultwarden-vm` group only. This is the default-deny that catches everything not allowed by steps 4 + 5. Pi-hole evaluates Allow before Deny, so `.*` only applies to lookups that didn't match.

Net effect: full resolution for allowlisted domains via Pi-hole's DoH upstream; every other domain returns `0.0.0.0` at DNS time. Each blocked attempt becomes a level-6 Wazuh alert (rule 100252, `status=blocked-regex`) so misconfigurations and unknown unknowns are immediately visible. Upstream-driven non-answers (Cloudflare Family filtering, domains with no A record, etc.) fire rule 100253 at level 4 instead — visible but distinct from "your allowlist policy hit."

#### Updating the allowlist later

- **Bulk section (step 4)**: edit the file in the repo, push, then **Tools → Update Gravity** in Pi-hole (or wait for the next scheduled gravity run, default daily). Pi-hole re-fetches the URL and reconciles the gravity DB; entries are added or removed to match the updated file. No need to re-add the list or restart anything.
- **Apex section (step 5)**: add or remove via the UI by hand. Mirror the change in the file's APEX section so the source of truth stays in the repo. The apex section being commented out means it doesn't break gravity but stays diff-able.
- **Squid mirror**: when you add a new outbound destination, also mirror in `proxy-home/vault_domains_allow_proxy.txt` and redeploy Squid.

#### Bootstrap / refinement workflow

After deploying the allowlist + deny, expect a flurry of `100252` alerts during the first few days as edge cases (rDNS / `*.in-addr.arpa`, search-list expansions, glibc opportunistic lookups, missed apex domains) hit the deny. Each one is either:

- **Legit Vault VM activity that's missing from the allowlist**: add the domain to both `proxy-home/vault_domains_allow_proxy.txt` and `vault_domains_allow_dns.txt`, push, redeploy Squid, run Update Gravity in Pi-hole.
- **DNS noise** (rDNS, search-list, etc.): for PTR queries on `*.in-addr.arpa` you'd need a wildcard match Pi-hole's gravity-format can't quite express, so add it as a manual Allow Regex like `(^|\.)in-addr\.arpa$` scoped to the `vaultwarden-vm` group, OR accept the failure (most apps degrade gracefully when rDNS fails).
- **Genuinely unexpected**: that's the alert earning its keep.

The noise floor settles to "real signal only" within a week or two.

### Operations cheat sheet

```bash
# === On the Pi-hole VM ===

# Confirm the FTL DB is reachable on the host
sudo sqlite3 -readonly /home/pi/pihole/data/etc-pihole/pihole-FTL.db \
  "SELECT count(*) FROM queries WHERE timestamp > strftime('%s','now','-1 hour')"

# Sidecar status + recent events
sudo systemctl status pihole-ftl-tail
sudo journalctl -u pihole-ftl-tail -n 20
sudo tail -f /var/log/vault-dns/events.log

# Confirm the wazuh-agent is tailing the merged log
sudo grep "vault-dns-events" /var/ossec/logs/ossec.log | tail
# expect: Analyzing file: '/var/log/vault-dns/events.log'

# === On wazuh-home ===

# Watch Vault-VM alerts arrive in real time
sudo tail -f /var/ossec/logs/alerts/alerts.json \
  | jq -r 'select(.rule.id=="100251" or .rule.id=="100252" or .rule.id=="100253") | "\(.timestamp) [\(.rule.id)] \(.data.qtype) \(.data.query) \(.data.status)"'

# Validate manager config after editing local_rules.xml
sudo /var/ossec/bin/wazuh-analysisd -t
```

### Planned next step (not yet implemented)

Right now every Vault VM DNS query alerts at level 3 (resolved) or level 6 (blocked). The next iteration adds **allowlist-anomaly detection**: extend the sidecar to read the Squid allowlist (`proxy-home/vault_domains_allow_proxy.txt`) and tag each event with an `allowed` boolean, then add a higher-level rule that fires only when a resolved query's domain is NOT on the allowlist. Sketch in [`wazuh-home/README.md`](./wazuh-home/README.md) under "Planned next step"; full design tracked in [ideas.md](ideas.md) #7 Phase C subsection "Allowlist-anomaly alert for the Vault VM".

---

## 📋 Log Pipeline

A map of every log this stack writes, what each one captures, and what consumes it. Two VMs, two perspectives.

### Vaultwarden VM

| Log file | What it captures | Currently consumed by | Future consumers |
|----------|------------------|------------------------|------------------|
| `/srv/vw-logs/vaultwarden.log` | Vaultwarden app log: failed logins, failed admin auth, failed 2FA (TOTP + email), app errors. Enabled via `EXTENDED_LOGGING=true` + `LOG_FILE` in compose. | CrowdSec (custom parsers in `crowdsec/parsers/vaultwarden-logs.yaml`, scenarios in `crowdsec/scenarios/vaultwarden-bf.yaml`) | Wazuh (planned, see [ideas.md](ideas.md) #7 Phase B) |
| `/srv/bw-logs/access.log` | Every BunkerWeb HTTP request, 200s, 4xx, 5xx, all of it. The full request log. | CrowdSec (hub-installed parsers for nginx access patterns) | Wazuh (planned) |
| `/srv/bw-logs/error.log` | Nginx errors at the proxy layer (upstream timeouts, config issues, etc.). | CrowdSec (hub-installed parsers) | Wazuh (planned) |
| `/srv/bw-logs/modsec_audit.log` | **Only WAF-triggered events** (`SecAuditLogParts ABCFHJKZ` with `RelevantOnly` selector): every CRS rule match with full request context. Currently detection-only, see [ModSecurity / OWASP CRS](#-modsecurity--owasp-crs-detection-only--work-in-progress). | Operator (manual review during exclusion tuning), CrowdSec (correlation with attack scenarios) | Wazuh (planned) |
| `/srv/bw-logs/bunkerweb.log`, `redis.log`, `scheduler.log`, `ui.log` | BW's own internal logs: scheduler runs, Redis state, web UI activity, top-level container output. | Operator (debugging) |, |
| `/srv/bw-logs/letsencrypt/*` | certbot logs from BW's bundled ACME flow. **Rotated internally by BW**, not in scope for the host logrotate config. | Operator (cert renewal debugging) |, |
| `/srv/logs/{main,backup,docker,system}/*.log` | Maintenance script logs, one file per phase per day. `main-YYYY-MM-DD.log` (orchestrator), `vault-backup-YYYY-MM-DD.log`, `update-YYYY-MM-DD.log` (docker), `system-autoupdate-YYYY-MM-DD.log`. 30-day retention enforced by `find -mtime +30 -delete` at the end of each phase script (NOT logrotate). | Operator, TrueNAS (pulled nightly via `truenas-script.sh`) | Wazuh (planned: structured JSONL status log per ideas.md #7 Phase A, then ingested by Phase B) |

### LAN Pi-hole VM

| Log file | What it captures | Currently consumed by | Future consumers |
|----------|------------------|------------------------|------------------|
| `/etc/pihole/pihole-FTL.db` (host bind: `/home/pi/pihole/data/etc-pihole/pihole-FTL.db`) | Pi-hole FTL's SQLite database: one row per resolved query in the `queries` view, with normalized columns for timestamp / qtype / status / domain / client / forward. Authoritative source of "what happened to this query." | Sidecar daemon `pihole-ftl-tail.py` (polls every 10s, filters to Vault VM, emits one JSON line per query to `/var/log/vault-dns/events.log`). See [`wazuh-home/`](./wazuh-home/) | Allowlist-anomaly extension to the sidecar (planned, see [ideas.md](ideas.md) #7) |
| `/var/log/vault-dns/events.log` | Sidecar output: one JSON line per Vault VM DNS query with `srcip / qtype / query / status / status_code / blocked / forward`. | Wazuh agent (tails the file as `log_format=json`; manager auto-decodes with built-in JSON decoder; rules 100250 / 100251 / 100252 / 100253 in [`wazuh-home/manager-rules.xml`](./wazuh-home/manager-rules.xml) fire per event) | n/a |

### Wazuh agent (current state)

Wazuh agents are installed and enrolled across three VMs in the homelab, with very different scopes per VM:

| VM | Agent state | What's actually shipping |
|----|-------------|--------------------------|
| Vaultwarden VM | Installed, enrolled, **stock defaults** | Nothing app-specific. No `<localfile>` entries for `vw-logs/` / `bw-logs/` / `main.sh` status; no custom FIM beyond defaults; no custom decoders or rules on the manager side scoped to this VM. Stock keepalives + base syscheck/inventory only. |
| `proxy-home` VM | Installed, enrolled, **stock defaults** | Stock keepalives + base syscheck/inventory only. With dnsproxy gone, the proxy-home VM has nothing application-specific to ship. |
| LAN Pi-hole VM | Installed, enrolled, **with custom localfile + sidecar daemon + manager-side rules** | `pihole-ftl-tail.py` daemon polls Pi-hole's FTL SQLite DB and emits structured JSON events to `/var/log/vault-dns/events.log`; agent ships those; manager rules 100250 / 100251 / 100252 / 100253 produce per-query alerts (resolved at level 3, Pi-hole-policy block at level 6, upstream no-answer at level 4) using Wazuh's built-in JSON decoder. Configuration in [`wazuh-home/`](./wazuh-home/). |

The Wazuh apt repo (`packages.wazuh.com`) is configured on each VM so the agent gets pulled in by normal `apt upgrade` cycles, the nightly `system-update.sh` phase on the Vaultwarden VM, and standard unattended-upgrades elsewhere. `packages.wazuh.com` is on the Vaultwarden VM's Squid allowlist (`proxy-home/vault_domains_allow_proxy.txt`) for that reason. Upgrade procedure documented upstream: [Wazuh agent, Linux upgrade guide](https://documentation.wazuh.com/current/upgrade-guide/wazuh-agent/linux.html).

The full Wazuh build-out for Vault-VM-internal logs (log shipping for `bw-logs/` + `vw-logs/` + `main.sh` JSON status, custom decoders, alert rules, Discord Active Response) is still ahead, tracked in [ideas.md](ideas.md) #7. The DNS visibility piece in [`wazuh-home/`](./wazuh-home/) is the first slice of it that's actually live.

### Where logs do NOT go

- **`stdout` for the application containers**, Vaultwarden's own log goes to `/srv/vw-logs/vaultwarden.log` (file mode), not container stdout. BW's logs likewise go to `/srv/bw-logs/`. Container stdout is bounded at 30 MB per container (`json-file` driver, 10m × 3 files) and only carries startup messages and unhandled errors. Don't `podman logs` for application-level events, read the files.
- **Off-box, in real time, for the Vaultwarden VM itself**, log shipping to Wazuh is **not yet wired up** (the agent is enrolled with `wazuh-home` but stock defaults apply on the Vault VM, no `<localfile>` entries for `vw-logs/` / `bw-logs/`, see [Wazuh agent (current state)](#wazuh-agent-current-state) below). All centralized retention happens at TrueNAS pull time, nightly. The DNS visibility piece is the only Vault-VM-related log stream currently flowing live into Wazuh, and that's because it's tapped at the Pi-hole side, not on the Vault VM.

### Consumer summary

- **CrowdSec**, tails `vaultwarden.log` + `access.log` + `error.log` + `modsec_audit.log` in real time, parses them, applies bouncer decisions back at BunkerWeb. The parser/scenario/whitelist files in `crowdsec/` are the contract between log format and detection rules.
- **TrueNAS**, pulls the encrypted backup bundle + the four `/srv/logs/{main,backup,docker,system}/` phase logs via scp using the `fetcher` user (see [Off-site replication](#off-site-replication-truenas-via-cron)).
- **Wazuh**, agent on the LAN Pi-hole VM ships the FTL-DB-sidecar's `/var/log/vault-dns/events.log` (structured JSON) live; manager rules 100251 / 100252 / 100253 in [`wazuh-home/`](./wazuh-home/) produce per-query alerts (resolved at level 3, Pi-hole-policy block at level 6, upstream no-answer at level 4) for the Vault VM. Agents on the Vaultwarden VM and `proxy-home` VM are enrolled but otherwise at stock defaults (no `vw-logs/` / `bw-logs/` shipping yet, see [ideas.md](ideas.md) #7).
- **Operator**, `tail -f` for live debugging; log files are the source of truth for everything except the BW internal scheduler/UI/Redis logs (those are debug-only).

---

## 🔁 Log Rotation

Vaultwarden, BunkerWeb's nginx workers, and the FTL-DB sidecar's output log all append indefinitely; none rotate themselves. Three host-side configs cover this across two VMs. They live in `/etc/logrotate.d/<name>` and are NOT checked into this repo (created by hand from the snippets below). Pi-hole's own `pihole.log` is rotated by Pi-hole's bundled logrotate setup, no extra config needed for that.

`copytruncate` is **load-bearing** in every config below: the standard logrotate mode (rename + create new file) changes the file's inode, and CrowdSec tails by file descriptor, it would keep reading the renamed (eventually compressed-and-deleted) file forever and miss new entries. `copytruncate` keeps the same inode and truncates in place, so its open fd keeps seeing fresh writes uninterrupted.

### Vaultwarden VM

#### `/etc/logrotate.d/vaultwarden`

```
/srv/vw-logs/vaultwarden.log {
    daily
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
```

#### `/etc/logrotate.d/bunkerweb`

```
/srv/bw-logs/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
```

The `letsencrypt/` subdir under `/srv/bw-logs/` is rotated internally by BunkerWeb's bundled certbot, the glob above won't recurse into it, which is intentional. Leave it alone.

### LAN Pi-hole VM

#### `/etc/logrotate.d/vault-dns`

Bounds the FTL-DB sidecar's output log. Install logrotate first if it isn't there (`sudo apt install logrotate`), then `sudo nano /etc/logrotate.d/vault-dns` and paste:

```
/var/log/vault-dns/events.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root root
}
```

`delaycompress` keeps yesterday's rotated file uncompressed so a quick `grep` works without `zgrep`. `notifempty` skips rotation when the sidecar hasn't emitted anything (e.g. Vault VM idle for a day). `create 0640 root root` is mostly redundant with `copytruncate` but pins the perms explicitly. Verify with `sudo logrotate -d /etc/logrotate.d/vault-dns` (dry-run); the daily run is invoked automatically by Debian's `/etc/cron.daily/logrotate` or systemd's `logrotate.timer`.


### Maintenance script logs (Vaultwarden VM)

Maintenance script logs at `/srv/logs/{main,backup,docker,system}/` are NOT rotated by logrotate, each phase script handles its own 30-day retention via `find -mtime +30 -delete` at the end of the run.

---

## 🐳 Container Startup and Podman User Configuration

Containers are started by the dedicated Podman user (`poduser`) instead of root to prevent environment variable exposure during startup.

### **Container Launch Configuration**

* Containers are launched at boot using the `poduser` crontab with:
  ```bash
  @reboot /bin/bash -lc '/home/poduser/vault/start-containers.sh'
  ```
* The `start-containers.sh` script performs system checks before starting `podman-compose`:
  - waits for a default network route to be present
  - waits until `/etc/resolv.conf` contains at least one `nameserver`
  - optionally waits for DNS resolution (e.g., `cloudflare.com`) to succeed
  After these checks, it runs `podman-compose up -d --force-recreate` from `/home/poduser/vault/`.
* These checks ensure the containers start safely by verifying network and DNS availability before bringing the stack up.

### **Global Podman Compose Aliases**

To simplify container management while keeping output suppressed globally (the compose file lists every env var on startup, including secrets), two helper functions are defined system-wide. Drop them into `/etc/profile.d/podman_compose_aliases.sh`:

```bash
# Global helpers for podman-compose
pcup() {
    podman-compose up -d >/dev/null 2>&1
}

pcdown() {
    podman-compose down >/dev/null 2>&1
}
```

Sourcing this system-wide means any user managing Podman containers can call `pcup` / `pcdown` without exposing sensitive output.

---

## 🔒 Security Features

* Running containers with **a dedicated Podman user** (not root)
* **No docker daemon installed**, podman-compose (under `poduser`) handles all compose parsing and lifecycle
* All certificate issuance + renewal happens **inside the BunkerWeb container** (no host-level Certbot exposure)
* Strong separation between privileged and unprivileged operations
* **Resource limits** on every container (memory + CPU caps via `deploy.resources.limits`)
* **Capability dropping**: every container starts with `cap_drop: ALL` and explicitly adds back only what it needs (typically `NET_BIND_SERVICE`, `CHOWN`, `DAC_OVERRIDE`, `SETGID`, `SETUID` for nginx; just `DAC_OVERRIDE` + `SETGID` + `SETUID` for CrowdSec)
* **`security_opt: no-new-privileges`** on every container, child processes can never gain privileges via setuid binaries
* **Read-only rootfs** on `cloudflared` and `vaultwarden` (BunkerWeb and CrowdSec need writable rootfs for their internal ops; named volumes still isolate writable state)
* **Backup signing** via [minisign](https://jedisct1.github.io/minisign/), every backup bundle is cryptographically signed; restore-time verification detects tampering at the storage layer

---

## 🛡️ Host hardening (Lynis, work in progress)

Periodically auditing the VM with [Lynis](https://cisofy.com/lynis/) and tracking the hardening index over time. Lynis catches OS-layer drift the container-level hardening doesn't touch: kernel sysctls, PAM, SSH config, package integrity, filesystem perms, etc. Run with `sudo lynis audit system` (`apt install lynis` from Debian's repo).

**Current baseline: 76 / 100** on this single-purpose Debian 13 VM running rootless Podman + BunkerWeb + CrowdSec + Vaultwarden.

### Base hardening pass (done)

* `/etc/sudoers.d` permissions tightened to mode 750
* Docker daemon removed entirely (was leftover from earlier debugging; on Debian 13's podman 5.x, `podman-compose config --services` produces clean output so docker is no longer needed for compose parsing)
* SSH already hardened in `sshd_config`: `AllowUsers` restriction, tightened `MaxAuthTries`, `ClientAliveInterval` / `ClientAliveCountMax` for stale-session timeout, `LoginGraceTime`, `PermitRootLogin`, `X11Forwarding off`, etc. Lynis flags only one remaining tweak (`PrintLastLog yes`, SSH-7408), tracked under "next pass" below.
* `libpam-tmpdir` for per-session `$TMPDIR` isolation (mitigates `/tmp` symlink and info-leak attacks)
* `apt-listbugs` installed to warn on critical/grave bugs in packages before each apt install
* `debsums` installed (the tool only; run on demand with `sudo debsums -c` to verify installed package files against their recorded checksums). The weekly automated run + matching ignore file are pending, see the next-pass list and the dedicated note below.

### Next pass (pending)

* Sysctl hardening (`kptr_restrict`, `bpf_jit_harden`, `rp_filter`, `log_martians`, `accept_redirects`, etc.) via `/etc/sysctl.d/99-hardening.conf` (KRNL-6000)
* Module blacklists for `usb-storage`, `firewire-ohci`, `dccp`, `sctp`, `rds`, `tipc` via `/etc/modprobe.d/99-blacklist-unused.conf` (USB-1000, STRG-1846, NETW-3200)
* Default umask `027` in `/etc/login.defs` (AUTH-9328)
* SSH `PrintLastLog yes` in `sshd_config` (SSH-7408)
* Legal banners on `/etc/issue` and `/etc/issue.net` (BANN-7126, BANN-7130)
* Weekly `debsums` cron via `/etc/default/debsums` (`CRON_CHECK=weekly`), plus an `/etc/debsums-ignore` file to filter wazuh-agent's installer-staging noise so the weekly run surfaces only genuine anomalies (see note below for the filter contents)

### Deliberate skips

A handful of Lynis suggestions are intentionally not acted on:

* **Single nameserver** (NETW-2705): the LAN Pi-hole is the trusted DNS chokepoint (DoH-encrypted upstream + queries logged into Wazuh); adding a fallback resolver would route around both, making it pointless.
* **Separate /home, /var partitions** (FILE-6310): overkill for a single-purpose 30 GB VM.
* **GRUB password** (BOOT-5122): low value when only the Proxmox console can boot the VM.
* **Remote logging** (LOGG-2154) and **malware scanner** (HRDN-7230): the Wazuh agent + syscheck cover both layers.
* **auditd / sysstat / process accounting** (ACCT-9622-9628): heavy maintenance burden for marginal value beyond what Wazuh already provides.
* **Locked accounts** (AUTH-9284): the one locked human-style account on this VM is `poduser`, intentionally locked since it's a service account that should never log in interactively (only `sudo su - poduser` from root). All other "locked" accounts in `/etc/shadow` are stock Debian system accounts (`systemd-network`, `dhcpcd`, `messagebus`, `sshd`, etc.) which is normal.
* **Password aging / hashing rounds** (AUTH-9286 / AUTH-9230): bureaucratic for a single-admin VM.

### Note on `debsums` noise from the Wazuh agent

When `debsums` checks installed packages, it flags ~150 "missing" files under `/var/ossec/packages_files/`. These aren't real anomalies. The wazuh-agent `.deb` package ships installer-staging files (templates for every distro Wazuh supports, CIS benchmark YAMLs, init scripts, etc.) that the installer uses during the agent setup and then cleans up because they're irrelevant once the agent is running on this specific distro. The package's recorded file list still references them, so `debsums` reports them as missing.

When the weekly `debsums` cron lands (in the pending list above), it'll be paired with an `/etc/debsums-ignore` file (one path per line, glob patterns OK) to suppress that noise so each run surfaces only genuine package-integrity issues. Planned contents:

```
/var/ossec/packages_files/*
/etc/init.d/wazuh-agent
/etc/systemd/system/wazuh-agent.service
```

Not yet created on this VM; tracked alongside the cron-scheduling task above.

---

## 🔐 Additional Security Layers

### **Security Headers**

The BunkerWeb proxy implements comprehensive HTTP security headers, achieving an **A+ rating** on [securityheaders.com](https://securityheaders.com).

#### **Why two custom config files instead of just env vars in the compose**

BunkerWeb ships its own headers plugin configurable via env vars (`CUSTOM_HEADER`, `STRICT_TRANSPORT_SECURITY`, `CONTENT_SECURITY_POLICY`, etc.). It would be tempting to just set those in the compose `environment:` block and call it done. We **deliberately don't**, for three reasons:

1. **Plugin-layer drift between BunkerWeb versions.** The env-var → emitted-header pipeline is BW's own logic: which headers get set, how they merge with upstream values, what defaults apply when an env is absent, what priority a setting has when a path-specific rule conflicts with a global one. Those internals shift between BW releases, env names get renamed, defaults change, the order of precedence between BW's plugin and upstream-supplied headers gets reworked. For a stack chasing an A+ headers grade, **silently losing a header on a BW image bump because a plugin default flipped** is a real outage risk that's invisible until someone re-runs `securityheaders.com`.
   - We use nginx's `more_set_headers` directive (from the `headers-more` module bundled with BW's nginx) instead. That's a stable nginx primitive, its behavior depends on nginx, not on BW's plugin layer. BW can rev across major versions and our header emission stays bit-identical.
2. **Vaultwarden owns CSP and X-Frame-Options per-endpoint.** Vaultwarden sets a different `Content-Security-Policy` on `/2fa-connector.html` (the Duo iframe) than on the rest of the app, and emits its own `X-Frame-Options` accordingly. If BW's plugin overwrites those with a single global value from an env var, **Duo 2FA breaks**. The right fix is to capture Vaultwarden's per-endpoint values from the upstream response and re-emit them downstream, which is what the http-scope `map` does. This isn't easily expressible as a compose env var; it requires nginx config.
3. **Two files because they operate at two different nginx scopes.** nginx requires `map` directives to live in the `http` block (top-level config), while the actual `more_set_headers` emission has to live in a `server` (or `location`) block. Splitting them isn't an aesthetic choice, it's the language structure:
    - **`http/headers-upstream-passthrough.conf`** declares two http-scope variables: `$bw_csp_out` and `$bw_xfo_out`. Each is a `map` that captures the upstream response's `Content-Security-Policy` / `X-Frame-Options` if Vaultwarden set one, falling back to a safe default otherwise.
    - **`server-http/headers-passthrough-apply.conf`** is the server-scope file that actually calls `more_set_headers ...` for every header in the table below. It references `$bw_csp_out` / `$bw_xfo_out` for the two pass-through headers, and hardcodes literal values for the rest (HSTS, Referrer-Policy, Permissions-Policy, etc.).

#### **What `REMOVE_HEADERS` env var stays for**

The `REMOVE_HEADERS: Server Via X-Powered-By X-AspNet-Version X-AspNetMvc-Version` line in compose is **not** an inconsistency with the above. It's a different mechanism, **suppression**, not injection. Stripping a header is a one-shot operation with no nuance about when/how/which value, so the version-drift concern doesn't apply. BW's plugin handles suppression cleanly across versions; reinventing that in nginx config would be busywork without a payoff.

#### **The closed loop: smoke-test on every BW image bump**

The two custom configs are only useful if we actually catch the moment they stop matching reality. Every time the BW image is bumped (manually, or via the `docker-update.sh` cycle that pulls latest tags), run:

```bash
curl -sI https://vault.example.com/
```

and diff the response headers against the table below. Any unexpected drop, addition, or value change → investigate before considering the upgrade clean. This is the only thing standing between "we own header emission" and "we own header emission **on paper**."

#### **Implemented Headers**

| Header | Value | Source | Purpose |
|--------|-------|--------|---------|
| **`Strict-Transport-Security`** | `max-age=31536000; includeSubDomains; preload` | BW custom config | Enforces HTTPS for 1 year, including all subdomains. Domain is [HSTS preloaded](https://hstspreload.org/) in browsers. |
| **`Content-Security-Policy`** | Passes through Vaultwarden's per-endpoint CSP via the http-scope `$bw_csp_out` map | Vaultwarden upstream → BW passthrough | Vaultwarden sets a comprehensive CSP that varies per endpoint (e.g., the Duo iframe on `/2fa-connector.html` needs different rules). The map captures the upstream value and re-emits it. |
| **`X-Frame-Options`** | Passes through Vaultwarden's value via `$bw_xfo_out` map | Vaultwarden upstream → BW passthrough | Same passthrough mechanism as CSP. |
| **`X-Content-Type-Options`** | `nosniff` | BW custom config | Prevents MIME type sniffing. |
| **`Referrer-Policy`** | `same-origin` | BW custom config | Limits referrer info to same-origin requests. |
| **`Permissions-Policy`** | `accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), display-capture=(), document-domain=(), encrypted-media=(), execution-while-not-rendered=(), execution-while-out-of-viewport=(), fullscreen=(), geolocation=(), gyroscope=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), screen-wake-lock=(), sync-xhr=(), usb=(), web-share=(), xr-spatial-tracking=()` | BW custom config | Disables 24 browser features unnecessary for a password manager. Notable: blocks FLoC tracking, sensor APIs, media capture, geolocation. Clipboard and WebAuthn remain enabled. |
| **`Cross-Origin-Opener-Policy`** | `same-origin` | BW custom config | Isolates the browsing context. Protects against Spectre-like attacks and cross-origin information leaks. |

Per-path overrides for `/robots.txt`, `/.well-known/security.txt`, and `/security.txt` (the latter redirects to the canonical path) are applied in `bunkerweb/custom-configs/server-http/security-txt-lang.conf`, which re-emits strict values inside `location` blocks.

#### **Removed Headers**

| Header | Removed by | Purpose |
|--------|------------|---------|
| **`Server`** | `REMOVE_HEADERS` env var | Removes server identification to prevent fingerprinting. |
| **`Via`** | `REMOVE_HEADERS` env var | Removes proxy hop information. |
| **`X-Powered-By`** / **`X-AspNet-Version`** / **`X-AspNetMvc-Version`** | `REMOVE_HEADERS` env var | Removes framework identification headers (defense-in-depth even if Vaultwarden never emits them). |

#### **Why These Matter for Vaultwarden**

Password managers are high-value targets. These headers provide defense-in-depth:

- **HSTS + Preload**: Ensures connections are always encrypted, even before the first request
- **CSP + X-Frame-Options**: Prevents UI redressing attacks that could trick users into revealing passwords
- **Permissions-Policy**: Blocks unnecessary browser APIs that could be exploited (camera, microphone, sensors)
- **COOP + Referrer-Policy**: Prevents cross-origin data leaks, including sensitive vault URLs
- **Server/Via removal**: Reduces information disclosure for potential attackers

---

### **Cloudflare**

* TLS **1.3 enforced** as the minimum version
* **Automatic HTTP → HTTPS redirection**
* **HSTS enabled** (max-age 12 months, include subdomains, preload)
* **Certificate Transparency Monitoring** to receive alerts on new certificate issuance
* **Full (strict) SSL/TLS** for end-to-end encryption with Let's Encrypt ([Cloudflare docs](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/))
* **Opportunistic Encryption disabled** to avoid unintended HTTP requests
* **Geo-blocking** for specific countries (but `robots.txt` remains globally accessible)
* **RUM script disabled** to prevent Cloudflare analytics injection ([Cloudflare docs](https://developers.cloudflare.com/speed/speed-test/rum-beacon/))
* **Zero-trust admin access**:

  * Accessing `/admin` triggers a Cloudflare Access login page
  * Only my GitHub account is allowed, adding another layer of protection before the Vaultwarden password prompt
* **DNS CAA records enforced** to restrict certificate issuance to only trusted Certificate Authorities, preventing unauthorized SSL/TLS certificates for the domain
* **HSTS Preload enabled**: Submitted the domain to [hstspreload.org](https://hstspreload.org/) to ensure browsers enforce HSTS by default, providing stronger protection against downgrade attacks
* **DNSSEC enabled**: The domain uses DNSSEC (Domain Name System Security Extensions) to cryptographically sign DNS records, protecting against DNS spoofing and ensuring the authenticity of DNS responses
* **Cloudflare Tunnel (`cloudflared`)** carries all inbound traffic to BunkerWeb, no host port is ever opened on the VM in the dns-challenge flavor

---

### **Vaultwarden Configuration**

The compose file enforces a tight access policy and a hardened icon-fetch path:

#### **Access policy**

| Variable | Value | Purpose |
|----------|-------|---------|
| `SIGNUPS_ALLOWED` | `false` | Prevents unauthorized account creation. |
| `INVITATIONS_ALLOWED` | `false` | Disables user-to-user invites. |
| `SENDS_ALLOWED` | `false` | Disables the file/note-sharing feature. Reduces attack surface; not needed in this setup. |
| `PASSWORD_HINTS_ALLOWED` | `false` | Disables the "forgot master password hint" flow. The hint itself leaks information about master-password patterns to anyone who knows the email. |
| `EMERGENCY_ACCESS_ALLOWED` | `false` | Disables the "emergency access contacts" feature. The delayed-takeover flow is an attack path if a contact account is ever compromised or configured by mistake. |
| `REQUIRE_DEVICE_EMAIL` | `true` | First login from a new device fingerprint sends an *informational* email (not a code-entry verification, that's `_enable_email_2fa`, opt-in per-user). With this `true`, the login *fails* if SMTP delivery fails, useful as an alarm + hard gate against silent unknown-device logins. Existing devices keep working regardless. |

#### **Icon fetching**

The previous setup disabled icon download entirely. The new setup uses Bitwarden's central icon CDN as a middle ground:

| Variable | Value | Purpose |
|----------|-------|---------|
| `ICON_SERVICE` | `bitwarden` | Tells clients to fetch favicons from `icons.bitwarden.net` directly (client-side, never through this server). Squid only needs to allow that one host instead of every domain a user saves. |
| `DISABLE_ICON_DOWNLOAD` | `true` | Belt-and-suspenders: kills VW's server-side icon fetcher entirely. Guards against (a) misbehaving clients hitting `/icons/<host>/icon.png`, (b) SSRF where `/icons/<attacker-host>/...` would otherwise trigger arbitrary outbound HTTP, (c) accidental future flip of `ICON_SERVICE` back to `internal`. |
| `ICON_CACHE_NEGTTL` | `0` | Disables negative icon caching (default 3-day NEGTTL would otherwise remember failed lookups for 72h). Inert today thanks to `DISABLE_ICON_DOWNLOAD`, but kept for clarity. |

Trade-off: with `ICON_SERVICE: bitwarden`, Bitwarden Inc. sees the domains your clients look up icons for (just the domain, no credentials). For most homelab setups that's an acceptable privacy cost vs. a chatty allowlist and SSRF surface.

#### **Real client IP**

| Variable | Value (dns-challenge) | Value (http-challenge) |
|----------|-----------------------|------------------------|
| `CLIENT_IP_HEADER` | `CF-Connecting-IP` | `X-Forwarded-For` |

dns-challenge: BunkerWeb's `USE_REAL_IP` rewrites `$remote_addr` from `CF-Connecting-IP` (set by Cloudflare's edge, forwarded by `cloudflared`); Vaultwarden then reads it from the same header.
http-challenge: BunkerWeb sees the real socket IP directly and forwards it as `X-Forwarded-For` upstream.

Either way, Vaultwarden logs the actual visitor IP, which is what the CrowdSec parser needs for ban decisions.

---

## 💾 Backup and Redundancy

Backups are encrypted using [age](https://github.com/FiloSottile/age) (modern public-key encryption) and signed using [minisign](https://jedisct1.github.io/minisign/) (Ed25519 signatures). The pair was chosen because:

* age replaces the previous OpenSSL-based hybrid encryption, system updates can silently change OpenSSL behavior and defaults, making old backups difficult to decrypt
* minisign was added so a stolen / corrupted backup at the storage layer (TrueNAS / Hetzner) is detectable at restore time, encryption alone proves "an attacker can't read it", not "an attacker hasn't replaced it"

The backup system is designed to be **reproducible**, **self-contained**, **future-proof**, and **tamper-evident**.

### **Design Principles**

* **Self-contained bundles**: Every bundle includes the exact age + minisign binaries (Linux + Windows) used for encryption / signing, a manifest with checksums, and decryption instructions. You only need the private key to decrypt and the public minisign key to verify.
* **Public key NOT bundled**: The minisign public key is **deliberately excluded** from each bundle, verifying a signature against a pubkey extracted from the same bundle proves nothing. Verifiers must use an externally-stored, trusted copy. The manifest records the pubkey *string* as a lookup hint for key-rotation scenarios.
* **Pinned binaries**: age and minisign are not installed via `apt`. Specific versions are downloaded from GitHub releases and stored at `/srv/tools/{age,minisign}/<version>/`. System updates cannot silently change the encryption / signing tools.
* **Version control**: Old binaries are never removed. `lib.sh` references specific `AGE_VERSION` and `MINISIGN_VERSION` constants that you update manually after running the corresponding `setup-*.sh`.
* **Public-key only on the server**: The VM only has the recipient public age key (`age1...`) and the minisign **private** key (for signing only, its corresponding public key for verification is stored on every external verifier instead). The age private key is generated and stored on a separate machine, never on the backup server.
* **Update awareness**: Each backup run checks GitHub for newer age + minisign releases and logs a warning, but never auto-updates.

### **Backup Bundle Structure**

Each daily backup produces a self-contained bundle:

```
vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz
├── vw-data-backup-YYYY-MM-DD.tar.gz.age            # age-encrypted backup archive
├── vw-data-backup-YYYY-MM-DD.tar.gz.age.minisig    # minisign signature
├── age                                              # age binary (Linux amd64)
├── age.exe                                          # age binary (Windows amd64)
├── minisign                                         # minisign binary (Linux amd64)
├── minisign.exe                                     # minisign binary (Windows amd64)
├── manifest-YYYY-MM-DD.txt                          # checksums + metadata
└── DECRYPT.txt                                      # step-by-step decryption + verification instructions
```

The manifest records:
* `timestamp`, backup creation time (UTC)
* `age_version`, pinned age version used (e.g., `v1.3.1`)
* `archive_sha256`, SHA-256 of the encrypted archive
* `age_binary_sha256` / `age_binary_win_sha256`, SHA-256 of the included age binaries
* `recipient_public_key`, the full `age1...` recipient pubkey
* `minisign_version`, pinned minisign version used
* `signature_sha256`, SHA-256 of the `.minisig` file
* `minisign_binary_sha256` / `minisign_binary_win_sha256`, SHA-256 of the included minisign binaries
* `minisign_pubkey`, the minisign pubkey (RW...) for cross-reference (NOT for verification, see "Design Principles")

### **Replication**

* Daily replication to **TrueNAS (local)** and **Hetzner Storage Box (cloud)** via `truenas-script.sh`
* Restricted SSH user for backup access, limiting exposure
* 90-day retention on TrueNAS and Hetzner; 30-day retention on the source VM

### **Failure modes and recovery**

* **Source VM dies entirely** → restore from any TrueNAS or Hetzner bundle. Need: age private key + minisign pubkey.
* **TrueNAS bundle is corrupt** → use the Hetzner copy (or vice versa). Verify via minisign before trusting.
* **TrueNAS bundle was tampered with** → minisign verification fails at restore, you don't decrypt with a poisoned bundle.
* **age private key lost** → no recovery. The backups are unrecoverable. (This is the core of the threat model: the private key MUST live somewhere off-site and survive the loss of the VM, TrueNAS, AND Hetzner simultaneously. A USB stick in a drawer is the standard answer.)
* **minisign private key (on the VM) lost** → existing backups still verify with the pubkey. New backups can't be signed until you generate a new keypair and update the verifier copy. Old backups remain trustworthy.

---

### 🔑 **Age Key Pair Generation**

The age key pair must be generated on a **separate machine** (not the Vaultwarden VM). The private key should **never** be on the backup server.

1. Download age for your OS from [GitHub releases](https://github.com/FiloSottile/age/releases):
   * **Windows**: `age-v1.3.1-windows-amd64.zip`
   * **macOS**: `age-v1.3.1-darwin-amd64.tar.gz` (or `darwin-arm64` for Apple Silicon)
   * **Linux**: `age-v1.3.1-linux-amd64.tar.gz`

2. Extract and open a terminal in the extracted directory

3. Generate a key pair:

   **Windows**:
   ```
   .\age-keygen.exe -o identity.txt
   ```

   **Linux / macOS**:
   ```bash
   ./age-keygen -o identity.txt
   ```

   This prints the public key (starting with `age1...`) and saves the full key pair to `identity.txt`.

4. Copy **only the public key line** (`age1...`) into a file called `age-recipient.txt`

5. Transfer `age-recipient.txt` to the Vaultwarden VM, into `${ROOT_VAULT_DIR}` (which is `/root/vault/`):
   ```
   scp -P 2222 age-recipient.txt user@vm-host:/tmp/
   # then on the VM:
   sudo install -m 600 -o root -g root /tmp/age-recipient.txt /root/vault/age-recipient.txt
   ```

6. Store `identity.txt` securely **offline** (USB drive, encrypted storage, or a separate secure machine). This is the **only** file that can decrypt your backups.

---

### 🔑 **Minisign Key Pair Generation**

Unlike the age key pair, the minisign **private** key must live ON the Vaultwarden VM (so `backup.sh` can sign each bundle unattended). The **public** key should be distributed to every verifier host (workstation, TrueNAS, restore-test machine).

Procedure:

1. On a clean machine (Windows / macOS / Linux), download minisign for your OS from [GitHub releases](https://github.com/jedisct1/minisign/releases) and extract to a folder NOT in any cloud-synced directory (USB stick is best).

2. Generate a passwordless keypair:

   ```bash
   ./minisign -G -W -p vw-backup.pub -s vw-backup.key
   ```

   The `-W` flag is **load-bearing**, it generates a keypair without a passphrase, required for unattended signing in `backup.sh`. Without `-W`, minisign 0.12+ will prompt for a passphrase and reject empty input.

3. Back up `vw-backup.key` offline (USB stick, paper printout in a safe). Losing it means you can't sign new bundles until you rotate keys; existing signed bundles remain verifiable as long as their pubkey is preserved.

4. Transfer to the VM at `/root/vault/minisign.key` and `/root/vault/minisign.pub`, mode `600 root:root`:

   ```bash
   scp vw-backup.{key,pub} user@vm-host:/tmp/
   # then on the VM:
   sudo mv /tmp/vw-backup.key /root/vault/minisign.key
   sudo mv /tmp/vw-backup.pub /root/vault/minisign.pub
   sudo chown root:root /root/vault/minisign.{key,pub}
   sudo chmod 600 /root/vault/minisign.{key,pub}
   ```

5. Distribute `vw-backup.pub` to every verifier (Windows workstation, TrueNAS, etc). The pubkey is not sensitive; the manifest in each backup bundle records its `RW...` string for cross-reference.

6. Wipe the temporary working directory once both keys are safely placed.

---

### 📦 **`setup-age.sh` Usage**

This script downloads and pins age binaries (Linux + Windows) from GitHub releases into versioned directories. It is used for the initial setup and for downloading newer versions when you choose to update. Old versions are **never** removed.

#### **Commands**

```bash
# Download the latest release from GitHub
sudo /root/vault/setup-age.sh

# Download a specific version
sudo /root/vault/setup-age.sh v1.3.1
```

If no version is specified, the script queries the [GitHub API](https://api.github.com/repos/FiloSottile/age/releases/latest) to determine the latest release automatically.

#### **What It Does**

1. Resolves the target version (from argument or GitHub API)
2. Checks if that version is already downloaded, skips if so
3. Downloads `age-{version}-linux-amd64.tar.gz` and `age-{version}-windows-amd64.zip` from GitHub releases
4. Uses `find` to locate the binaries inside the extracted archives (resilient to upstream changing the internal directory layout)
5. Installs `age`, `age-keygen`, `age.exe`, and `age-keygen.exe` into `/srv/tools/age/{version}/`
6. Computes and stores SHA-256 checksums for all binaries
7. Prints a summary with checksums and a reminder to update `AGE_VERSION` in `lib.sh`

#### **Directory Layout**

After running `./setup-age.sh v1.3.1`:

```
/srv/tools/age/
└── v1.3.1/
    ├── age                        # Linux amd64 binary
    ├── age.sha256
    ├── age-keygen
    ├── age-keygen.sha256
    ├── age.exe                    # Windows amd64 binary
    ├── age.exe.sha256
    ├── age-keygen.exe
    └── age-keygen.exe.sha256
```

Multiple versions can coexist side by side, old versions are kept in place so previous backups (which include their exact binary) remain verifiable / decryptable.

#### **After Downloading a New Version**

The script only downloads, it does **not** activate the new version automatically. To start using it for backups, manually update the version constant in `lib.sh`:

```bash
AGE_VERSION="v1.3.1"
```

This deliberate step ensures you are always in control of which version encrypts your backups.

---

### 📦 **`setup-minisign.sh` Usage**

Mirror of `setup-age.sh` for minisign. Same flow, same versioned directory layout, same "manually update the constant" finishing step.

```bash
# Download the latest release from GitHub
sudo /root/vault/setup-minisign.sh

# Download a specific version
sudo /root/vault/setup-minisign.sh 0.12
```

After running, update `MINISIGN_VERSION` in `lib.sh`:

```bash
MINISIGN_VERSION="0.12"
```

> **Note**: neither `age` nor `minisign` is added to `PATH`. Callers must use the full `${AGE_BINARY}` / `${MINISIGN_BINARY}` paths (which `lib.sh` builds from `AGE_VERSION` / `MINISIGN_VERSION`). All scripts in `root_scripts/` already do this; humans running either tool by hand need to remember (e.g., `/srv/tools/age/v1.3.1/age -d ...`, `/srv/tools/minisign/0.12/minisign -V ...`).

> **Upstream signature verification**: `setup-age.sh` and `setup-minisign.sh` currently trust GitHub's HTTPS only, they do not verify upstream signatures of the downloaded binaries. This is tracked as `ideas.md` #8, the planned approach is `gh attestation verify` (one unified verifier for any GitHub-released artifact, including future tooling we add).

---

### 🔓 **Decrypting a Backup**

Each backup bundle is **self-contained** and includes age + minisign binaries for both Linux and Windows. See `DECRYPT.txt` (included in every bundle) for detailed step-by-step instructions. High-level flow:

1. **Extract the outer bundle**, `tar xzf vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz`
2. **Verify the signature** (CRITICAL, do not skip):
   ```bash
   ./minisign -V -p /path/to/your-trusted-minisign.pub -m vw-data-backup-YYYY-MM-DD.tar.gz.age
   ```
   Expected output: `Signature and comment signature verified`. **Anything else → STOP**, the bundle is compromised or corrupt at the backup destination. Don't decrypt.
3. **(Optional) Verify checksums**, compare against `manifest-YYYY-MM-DD.txt`. Redundant if step 2 passed (the signature covers the encrypted archive cryptographically); useful for older unsigned bundles only.
4. **Decrypt**:
   ```bash
   ./age -d -i /path/to/identity.txt -o vw-data-backup-YYYY-MM-DD.tar.gz vw-data-backup-YYYY-MM-DD.tar.gz.age
   ```
5. **Extract the decrypted archive into a fresh sub-directory** so it doesn't dump 60+ files into wherever you're sitting:
   ```bash
   mkdir vw-data-restore-YYYY-MM-DD
   tar xzf vw-data-backup-YYYY-MM-DD.tar.gz -C vw-data-restore-YYYY-MM-DD
   ```

The restored directory contents are what should be placed at `/srv/vw-data/` on a fresh VM (with `vaultwarden:vaultwarden` ownership, mode `750`). Restart the stack with `podman-compose up -d`.

---

### 🔄 **Updating age / minisign**

To update either tool:

1. On the Vaultwarden VM, run the corresponding setup script with no args (downloads latest) or a specific version:
   ```bash
   sudo /root/vault/setup-age.sh
   sudo /root/vault/setup-minisign.sh
   ```

2. Update `AGE_VERSION` or `MINISIGN_VERSION` in `lib.sh`.

3. The next nightly `main.sh` run picks up the new version automatically.

The old version remains at `/srv/tools/{age,minisign}/{old-version}/` and is never deleted. Previous backups still include the exact binaries they were encrypted/signed with, so they remain verifiable and decryptable indefinitely.

---

## 📚 Further Reading

* **`ideas.md`**, numbered list of pending hardening / improvement ideas (gh-attestation supply-chain verification, Wazuh-native alerting to replace the deadman switch, etc, more to come)
* **`REBUILD.md`**, step-by-step VM rebuild procedure
