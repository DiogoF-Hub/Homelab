# Homelab

This repository contains my personal **homelab configurations and scripts** for services like **Vaultwarden**, **Pi-hole**, and **custom HTTPS certificate generation**. It includes everything from Docker / Podman Compose files to automation scripts that make deploying, updating, and maintaining these services much easier.

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
│   ├── docker-compose.cf-tunnel.yml          # production (Cloudflare Tunnel + ACME DNS-01)
│   ├── docker-compose.public-http01.yml      # direct host ports 80+443 + ACME HTTP-01
│   ├── docker-compose.public-dns01.yml       # direct host port 443 only (no port 80) + ACME DNS-01
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

  * **Cloudflare Tunnel (`cloudflared`)** as the public-facing edge: no host ports exposed; all inbound traffic arrives via an outbound-initiated tunnel
  * **BunkerWeb** handles ACME (Let's Encrypt DNS-01), TLS termination, security headers, country / user-agent blacklists, rate limiting, ModSecurity / CRS WAF, and the CrowdSec bouncer in one place
  * Three mutually-exclusive compose flavors: `docker-compose.cf-tunnel.yml` (canonical / production, behind Cloudflare Tunnel + DNS-01), `docker-compose.public-http01.yml` (direct host ports 80+443 + HTTP-01), and `docker-compose.public-dns01.yml` (direct host port 443 only, no port 80 listener at all + DNS-01)
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
