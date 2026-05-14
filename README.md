# Homelab

This repository contains my personal **homelab configurations and scripts** for services like **Vaultwarden**, **Pi-hole**, a **Minecraft server**, and **custom HTTPS certificate generation**. It includes everything from Docker / Podman Compose files to automation scripts that make deploying, updating, and maintaining these services much easier.

The goal is to **share my setup publicly** so others can learn, adapt, or get inspiration for their own homelab environments. The only thing I kindly ask is that if you find something that could improve security or make the setup better, please let me know so I can learn and improve as well.

---

## 📂 Repository Structure

```
Homelab/
├── PiHole/
│   ├── .env
│   ├── README.md
│   ├── blocklist.txt
│   ├── cookielist_whitelist.txt
│   ├── docker-compose.yml
│   ├── main.sh
│   ├── manual_domains_block.txt
│   ├── mycustom_list.txt
│   ├── root_crontab.txt
│   └── start-containers.sh
│
├── Vaultwarden/
│   ├── .env.template
│   ├── README.md
│   ├── REBUILD.md
│   ├── DECRYPT.txt
│   ├── ideas.md
│   ├── docker-compose.public-dns01.yml       # WHAT I RUN: direct host ports 80+443 + ACME DNS-01, paired with the edge VPS in Vaultwarden/vps/ (TCP passthrough + PROXY protocol)
│   ├── docker-compose.public-http01.yml      # reference only, not running it: direct host ports 80+443 + ACME HTTP-01
│   ├── docker-compose.cf-tunnel.yml          # reference only, not running it: Cloudflare Tunnel + ACME DNS-01 (CF terminates TLS at edge, sees plaintext password-manager traffic, unacceptable for this threat model)
│   ├── poduser_crontab.txt
│   ├── root_crontab.txt
│   ├── bunkerweb/                            # mounted into the BunkerWeb container
│   │   ├── robots.txt
│   │   ├── security.txt
│   │   └── custom-configs/                   # http / server-http / modsec / modsec-crs overlays
│   ├── crowdsec/                             # mounted into the CrowdSec container
│   │   ├── acquis.d/                         # log acquisition (BunkerWeb + Vaultwarden)
│   │   ├── parsers/                          # custom Vaultwarden log parser
│   │   ├── scenarios/                        # tightened bruteforce + user-enum scenarios
│   │   └── whitelists/                       # admin-diagnostics false-positive drop
│   ├── proxy-home/                           # targets the separate proxy-home VM (Squid HTTP/HTTPS egress only; DNS now via the LAN Pi-hole)
│   │   ├── squid.conf
│   │   └── vault_domains_allow_proxy.txt
│   ├── vps/                                  # targets the public-facing edge VPS (Hetzner CX23 Falkenstein, TCP passthrough back home via WireGuard with PROXY protocol for real-IP preservation, no TLS termination on the VPS)
│   │   ├── README.md                         # VPS provisioning + ops doc (Hetzner setup, PTR, DNS, UFW, WireGuard, nginx stream + PROXY, OPNsense WG, CrowdSec firewall bouncer)
│   │   ├── crowdsec/                         # CrowdSec firewall bouncer config (nftables, pulls bans from home LAPI over the WG tunnel, drops banned IPs at the VPS edge)
│   │   ├── nginx/                            # nginx stream config (raw TCP passthrough with PROXY protocol)
│   │   ├── scripts/                          # nightly maintenance: auto-update.sh (apt + unconditional reboot) + root_crontab.txt
│   │   └── wireguard/                        # WG tunnel config template
│   ├── vault_domains_allow_dns.txt           # Pi-hole allowlist for the vaultwarden-vm group (gravity/ABP-syntax mirror of the Squid allowlist; consumed via Pi-hole's "Add allowlist" URL feature)
│   ├── wazuh-home/                           # Targets the wazuh-home VM (Wazuh manager) + sidecar daemon for the LAN Pi-hole VM
│   │   ├── README.md
│   │   ├── pihole-agent.localfile.xml        # <localfile> blocks for the Pi-hole VM's wazuh-agent
│   │   ├── manager-global.snippet.xml        # logall_json toggle for the wazuh-home <global> block
│   │   ├── manager-rules.xml                 # rules 100250 / 100251 / 100252 (archive base + resolved + blocked)
│   │   └── sidecar/
│   │       ├── pihole-ftl-tail.py            # Daemon: polls Pi-hole's FTL SQLite DB, emits one JSON event per Vault VM query
│   │       └── pihole-ftl-tail.service       # systemd unit (root, hardened, 10s polling tick)
│   └── scripts/
│       ├── root_scripts/                     # nightly orchestrator + phase scripts
│       │   ├── lib.sh
│       │   ├── main.sh
│       │   ├── backup.sh
│       │   ├── docker-update.sh
│       │   ├── system-update.sh
│       │   └── reboot.sh
│       ├── setups_scripts/                   # one-time installers (age + minisign pinning)
│       │   ├── setup-age.sh
│       │   └── setup-minisign.sh
│       ├── poduser_scripts/
│       │   └── start-containers.sh
│       └── truenas_scripts/
│           └── truenas-script.sh
│
├── Minecraft-Server/
│   ├── README.md
│   ├── .env.template
│   ├── docker-compose.yml                    # velocity + velocity-lan + minecraft (Fabric)
│   ├── vps-nginx-snippet.conf                # VPS-side nginx stream block (PROXY protocol on)
│   ├── FabricProxy-Lite.toml.example         # backend mod config; deploy to data/config/FabricProxy-Lite.toml
│   ├── backup.sh                             # RCON-warned tar of data/
│   ├── crontab.txt                           # reference root crontab entry for backup.sh
│   ├── velocity/                             # VPS-facing Velocity (PROXY-protocol input, modern forwarding out)
│   │   ├── velocity.toml
│   │   └── forwarding.secret.example
│   └── velocity-lan/                         # LAN-facing Velocity (plain TCP input, modern forwarding out)
│       ├── velocity.toml
│       └── forwarding.secret.example
│
├── HTTPS Generator/
│   ├── README.md
│   └── generate_cert.sh
│
└── Tailscale Windows VPN on demand/
    └── README.md                             # migrated to a dedicated repo (read-only reference)
```

---

## 🛠 Services

### **Pi-hole**

* **Features**

  * Network-wide ad and tracker blocking
  * DNS-over-HTTPS (DoH) to Cloudflare Family via `adguard/dnsproxy`
  * HTTPS-only web interface on port 443
  * Custom blocklists, manual domain blocking, and a cookie-consent platform whitelist to prevent banner breakage
* **Scripts**

  * `main.sh` for daily maintenance (gravity update → stop containers → image update → system update → reboot)
  * `start-containers.sh` to bring services up at boot
  * `root_crontab.txt` documenting the cron entries

---

### **Vaultwarden**

Self-hosted password manager running on a **dedicated Debian 13 VM in Proxmox**, with a dedicated NIC bound to **VLAN-DMZ**. Containers run under **rootless Podman** as a non-privileged `poduser`. The reverse-proxy / WAF / bouncer layer was migrated from **Caddy + Certbot + a Cloudflare Workers bouncer (host-installed CrowdSec)** to a single **BunkerWeb** all-in-one container, with CrowdSec also moved into a container.

* **Edge & proxy**

  * **Hetzner Cloud VPS (CX23, Falkenstein)** as the public-facing edge today. Runs nginx as a raw TCP **stream proxy** with **PROXY protocol** for ports 80 / 443 and forwards every byte over an encrypted **WireGuard tunnel** back to OPNsense, which routes the inner connection to BunkerWeb on the DMZ VLAN. Crucially, **TLS terminates at home, not at the VPS**, the Let's Encrypt private key never leaves the home BunkerWeb container, so a VPS compromise yields encrypted streams only. PROXY protocol preserves the real client IP through the chain so CrowdSec / rate-limiting / country blacklist all work on real visitors. Full provisioning runbook in [`Vaultwarden/vps/README.md`](Vaultwarden/vps/README.md).
  * **BunkerWeb** at home handles ACME (Let's Encrypt DNS-01 via Cloudflare API), TLS termination, security headers, country / user-agent blacklists, rate limiting, ModSecurity / CRS WAF, and the CrowdSec bouncer in one place
  * Three mutually-exclusive compose flavors. **What I run**: `docker-compose.public-dns01.yml` (direct host ports 80+443 + DNS-01, paired with the edge VPS doing TCP passthrough with PROXY protocol). The other two, `docker-compose.cf-tunnel.yml` (Cloudflare Tunnel + DNS-01) and `docker-compose.public-http01.yml` (direct host ports 80+443 + HTTP-01), are kept in the repo as reference for anyone evaluating different deployment options for their own setup, but I'm not running them
* **Intrusion prevention**

  * **Containerized CrowdSec** with custom Vaultwarden parsers, tightened bruteforce + user-enumeration scenarios, and an admin-diagnostics whitelist
  * Bans enforced **inline at BunkerWeb** (returns 403), no separate Cloudflare Worker
* **Outbound isolation**

  * Egress is default-deny on the VM and routed through two upstream chokepoints:

    * **Squid** on the **`proxy-home` VM** for HTTP / HTTPS egress, enforced against a domain allowlist (`vault_domains_allow_proxy.txt`)
    * **The homelab's LAN Pi-hole** for DNS, with DoH-encrypted upstream to Cloudflare Family and full per-query visibility via Wazuh (custom decoder + rule chain in `Vaultwarden/wazuh-home/` elevates every Vault-VM-srcip query to a level-3 alert)
* **Backups & redundancy**

  * Daily encrypted backups via **[age](https://github.com/FiloSottile/age)** (pinned binaries, public-key-only on the VM) and cryptographically signed with **[minisign](https://jedisct1.github.io/minisign/)** for tamper detection
  * Automated off-site replication to **TrueNAS** (local) and a **Hetzner Storage Box** (cloud)
* **Automation**

  * `scripts/root_scripts/main.sh` orchestrates the nightly cycle: stop containers → encrypted + signed backup → image update → full system update → unconditional reboot, with per-phase logs and 30-day retention
  * `scripts/setups_scripts/` pins the `age` and `minisign` binaries during VM rebuild / version bumps
  * `scripts/poduser_scripts/start-containers.sh` runs at `@reboot` to bring the stack back up
  * `scripts/truenas_scripts/truenas-script.sh` runs on the TrueNAS host to pull backups + logs and push them to Hetzner

See [`Vaultwarden/README.md`](./Vaultwarden/README.md) for the full deployment, log-pipeline, and firewall documentation, [`Vaultwarden/REBUILD.md`](./Vaultwarden/REBUILD.md) for the VM rebuild procedure, and [`Vaultwarden/DECRYPT.txt`](./Vaultwarden/DECRYPT.txt) for backup-restore instructions.

---

### **Minecraft**

Fabric-based Minecraft server with a **Velocity** proxy in front for proper Mojang auth and real-IP forwarding. Same edge pattern as Vaultwarden: TCP passthrough from the public VPS over a WireGuard tunnel, no TLS termination on the edge.

* **Architecture**

  * VPS nginx (stream `proxy_pass` with `proxy_protocol on`) → WireGuard tunnel → `velocity` at home (decodes PROXY header, does the Mojang session check, forwards via Velocity's "modern" handshake) → Fabric backend with **FabricProxy-Lite** (trusts the forwarded online UUID + real client IP). The backend is in `online-mode=false` but operates effectively online via the verified handshake.
  * A second proxy instance, `velocity-lan`, listens on port 25566 for plain TCP so LAN players can connect directly without round-tripping through the VPS. Both proxies converge on the same backend with the same modern-forwarding secret.
* **Auth + whitelist**: pirate / cracked clients are rejected at Velocity (Mojang session check). The backend whitelist gates by real online UUIDs because the modern-forwarding handshake hands those over from Velocity, so `ENFORCE_WHITELIST=true` behaves exactly as on a vanilla `online-mode=true` server.
* **Mods**: not a published CurseForge / Modrinth modpack. Jars drop into `mods/` on the VM, and `itzg/minecraft-server` stages them into `/data/mods` on each boot. FabricProxy-Lite (+ its Fabric API dependency) is auto-installed from Modrinth via the `MODRINTH_PROJECTS` env var, matched to whatever MC + Fabric Loader versions you pinned in compose (the file ships with example values, change to suit your modpack).
* **Backups**: `backup.sh` warns players via RCON, stops the stack, tars `data/` into `backups/`, restarts, and prunes old logs. Cron-driven.

See [`Minecraft-Server/README.md`](./Minecraft-Server/README.md) for the full deployment runbook (VM, VPS, OPNsense), mod-add workflow, the CurseForge `AUTO_CURSEFORGE` alternative, and secret rotation.

---

### **HTTPS Generator**

* **Features**

  * Creates a **root CA** (ECDSA P-384, 20-year validity) for signing device certificates
  * Generates **device-specific certificates** (825-day validity for iOS compatibility) with proper SAN support

    * Hostname, `.localdomain`, optional **Tailscale tailnet** entries
    * Optional IP addresses
  * Single self-contained script, no external `openssl.cnf`; the configuration is generated inline at runtime
  * Configuration cached in `generator.conf` (gitignored)
* **Usage**

  * `generate_cert.sh` to create certificates for services or devices
  * Root CA (`rootCA.pem`) can be installed on devices (rename to `.crt` if needed)

---

### **Tailscale Windows VPN On-Demand**

This setup has been **migrated to its own dedicated repository**; the folder here is kept only as a read-only pointer. See [`Tailscale Windows VPN on demand/README.md`](./Tailscale%20Windows%20VPN%20on%20demand/README.md) for the link.

---

## 🚀 Goals

* Keep configurations version-controlled and organized
* Share a reproducible and secure setup for self-hosted services
* Maintain well-documented automation that's easy to manage and evolve as the homelab grows

---

## ⚠️ Disclaimer

These configurations are tailored to my environment.
Before using them, **review and customize** for your own domain, network, and security settings.
