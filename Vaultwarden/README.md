# Vaultwarden Setup

This folder contains my **Vaultwarden configuration and automation scripts**, originally based on **Docker** but now progressively migrating to **Podman**.

I've made a **full switch to running containers with [Podman](https://podman.io/)** for better security and system integration.
A **dedicated non-privileged user** (`poduser`) is used to run Podman containers.

However, **Docker remains installed** on the system to use certain commands, such as:

```bash
docker compose config --services
```

This allows me to easily list the services in a compose file without affecting container runtime.

**Important:** `poduser` is **not** in the Docker group and cannot run Docker commands without `sudo`. Since `poduser` also has **no sudo privileges**, only root can execute Docker commands. This isolation ensures `poduser` can only interact with Podman, preventing privilege escalation and maintaining strict separation between the runtime (Podman) and parsing tools (Docker CLI).

The setup is designed for **secure self-hosted password management**, with:

* **[Cloudflare](#cloudflare)** for globally exposing the service with TLS 1.3, HSTS preload, and Zero Trust access control
* **[Caddy reverse proxy](#caddy-reverse-proxy-caddyfile)** for HTTPS, security headers, a `robots.txt` file, and a `security.txt` file for vulnerability reporting
* **[CrowdSec integration](#%EF%B8%8F-crowdsec-integration)** for active protection with automatic IP banning of malicious actors
* **[Squid proxy](#-network-and-proxy-configuration)** for reliable outbound domain allowlisting and traffic control
* **[Daily automated maintenance](#-automation-scripts)** via `main.sh`: [age](https://github.com/FiloSottile/age)-encrypted backups, image updates, full system update, and reboot
* **[Automated off-site replication](#-automation-scripts)** to TrueNAS and Hetzner Storage Box
* **Strict [Cloudflare](#cloudflare) security policies** for zero trust access
* **Full network isolation** by running on a dedicated VLAN with [strict firewall rules in OPNsense](#-dmz-firewall-rules)
* **Hosted on a dedicated Debian 13 VM in Proxmox** with dedicated NIC binding for VLAN isolation and full system backup capabilities
* **[Self-contained backup encryption](#backup-and-redundancy)** using pinned [age](https://github.com/FiloSottile/age) binaries with version-controlled, reproducible, public-key-only encryption


Everything here is public for transparency and to help others learn, but you **must adapt the configuration to your own environment** before using it.

---

## 📂 Structure

```
Vaultwarden/
├── .env                              # Environment variables
├── Caddyfile                         # Caddy reverse-proxy configuration (HTTPS, headers, robots.txt)
├── certbot.conf                      # Certbot DNS configuration for Cloudflare
├── crowdsec-vaultwarden-bf.yaml      # CrowdSec brute force scenario configuration
├── crowdsec-vaultwarden-enum.yaml    # CrowdSec user enumeration scenario configuration
├── DECRYPT.txt                       # Decryption instructions (also bundled with every backup)
├── docker-compose.yml                # Compose configuration (used by Podman + Docker for parsing)
├── main.sh                           # Daily maintenance and update script
├── podman_compose_aliases.sh         # Global helper aliases for podman-compose (pcup/pcdown)
├── poduser_crontab.txt               # Crontab entries for poduser (container startup)
├── robots.txt                        # Disallows bots from indexing sensitive paths
├── security.txt                      # Contact info for reporting vulnerabilities (served at /.well-known/security.txt)
├── root_crontab.txt                  # Crontab entries for root automation
├── squid.conf                        # Squid proxy configuration for domain allowlisting
├── start-containers.sh               # Startup script (run at boot via poduser crontab)
├── vault_domains_allow_proxy.txt     # List of domains allowed for the Squid proxy
├── truenas-script.sh                 # Script on TrueNAS to pull backups and logs
├── deploy-hook.sh                    # Certbot deploy hook: copies renewed certificates to a directory where `poduser` can access them and restarts the Caddy server
├── setup-age.sh                      # Downloads and pins age encryption binaries from GitHub releases
└── README.md                         # This documentation
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

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

This file defines the core variables for your setup.
A template is provided as `.env.template` in this repository.

Example template:

```bash
ADMIN_TOKEN=''         # admin panel token (must be generated inside the Vaultwarden container because it outputs a password hash)
CLOUD_TOKEN=''         # Optional token for Cloudflare Tunnel integration
DOMAIN=''              # Your domain (e.g., vault.example.com)

# SMTP settings for email notifications
SMTP_HOST=''
SMTP_PORT=''
SMTP_SECURITY=''       # tls or ssl
SMTP_USERNAME=''
SMTP_PASSWORD=''
SMTP_FROM=''
SMTP_FROM_NAME=''
SMTP_TIMEOUT=''
```

I personally used [Mailjet](https://www.mailjet.com) provider.

---

### **Caddy Reverse Proxy (`Caddyfile`)**

* Provides **HTTPS** for Vaultwarden with **TLS 1.3** enforced as the minimum version
* Implements **additional security headers** beyond what Vaultwarden applies by default (see [Security Headers](#-additional-security-layers) section for full details)
* Hosts a `robots.txt` file (Vaultwarden does not natively support it)
* Hosts a `security.txt` file at `/.well-known/security.txt` to provide contact information for vulnerability reporting (see [security.txt standard](https://securitytxt.org/))

---

### **Certbot Configuration (`certbot.conf`)**

* Uses the **Cloudflare DNS plugin** with an API token to:

  * Automatically update DNS records
  * Request and renew Let’s Encrypt certificates
* Ensures **([Full (strict) SSL/TLS](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/))** encryption between Cloudflare and the server

---

### **Podman + Docker Compose**

* Podman is used to **run all containers** in production.
* Docker is kept installed to use convenient `docker compose` commands (like `config --services`) for parsing compose files.
* A dedicated non-root user (`poduser`) runs Podman containers, improving security.
* **Important:** `poduser` is **not** in the Docker group and cannot run Docker commands without `sudo`. Since `poduser` also has **no sudo privileges**, only root can execute Docker commands. This ensures strict separation between the runtime (Podman) and parsing tools (Docker CLI).
* Docker commands are only executed by root in `main.sh` for automated container image updates.

---

## 🔄 Automation Scripts

| Script                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`start-containers.sh`** | Starts containers at boot via `poduser` crontab.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **`main.sh`**             | Full daily maintenance script:<br>1. Stops containers safely<br>2. Creates an **encrypted backup** using [age](https://github.com/FiloSottile/age) public-key encryption:<br>   • Encrypts the backup archive with a pinned age binary using the recipient public key (X25519)<br>   • Generates a manifest with checksums, age version, and recipient key<br>   • Bundles the encrypted archive, the exact age binary used, a manifest, and decryption instructions into a self-contained archive<br>   • Checks GitHub for newer age releases and logs a warning (never auto-updates)<br>3. Updates images<br>4. Runs a full system update and **does a reboot**.<br>5. Places logs and encrypted backups in a dedicated folder with permissions adjusted for the `fetcher` user to access via `scp`. |
| **`setup-age.sh`**        | Downloads and pins [age](https://github.com/FiloSottile/age) encryption binaries from GitHub releases into versioned directories at `/srv/tools/age/`. Old versions are never removed. Run with no arguments to download the latest release, or specify a version (e.g., `./setup-age.sh v1.3.1`). After downloading, manually update `AGE_VERSION` in `main.sh` to use the new version. |
| **`truenas-script.sh`**   | Runs on TrueNAS to fetch daily encrypted backups and logs via `scp` using a **restricted `fetcher` user** (no sudo privileges). After fetching locally, it pushes a copy to the **Hetzner Storage Box**, ensuring redundancy:<br>• Local backups on TrueNAS<br>• Cloud backups on Hetzner                                                                                                                                                                                                                                                                                                 |
| **`deploy-hook.sh`**      | Certbot deploy hook: **copies renewed certificates to a directory accessible by `poduser`** and **restarts the Caddy server** to apply the new certificates.                                                                                                                                                                                                                                                                                                                                                                                                               |

---


## 🔒 Security Features

* Running containers with **a dedicated Podman user** (not root)
* **Docker group not used**, minimizing unnecessary privileges
* Docker kept only for parsing compose files, not running workloads
* Certificates are renewed with Certbot and securely made available to `poduser` through `deploy-hook.sh`
* Strong separation between privileged and unprivileged operations

---

## 🧱 DMZ Firewall Rules

The Vaultwarden service is isolated on its **own VLAN (VLAN-DMZ)** behind strict ingress and egress rules ensure that only **essential traffic** is allowed, minimizing the attack surface.

| # | Action | Protocol  | Source     | Destination                                                                                 | Port     | Description                        | Log |
|---|--------|-----------|-----------|---------------------------------------------------------------------------------------------|----------|-------------------------------------|-----|
| 1 | Pass   | TCP       | VLAN-DMZ  | 192.168.173.9 (SQUID proxy)                                                                 | 3128     | Allow Access to Proxy-Server       | Yes |
| 2 | Block  | Any       | VLAN-DMZ  | (Any other VLANs)                                                                           | Any      | Block DMZ to other VLANs           | Yes |
| 3 | Pass   | TCP/UDP   | VLAN-DMZ  | DNS_Providers (Cloudflare and Quad9)                                                        | 53       | Allow DNS                          | Yes |
| 4 | Pass   | UDP       | VLAN-DMZ  | This Firewall                                                                              | 123      | Allow NTP                          | Yes |
| 5 | Pass   | UDP       | VLAN-DMZ  | [Cloudflare_IPs](https://www.cloudflare.com/ips/)                                          | 7844 | Allow QUIC from Cloudflare         | Yes |
| 6 | Pass   | TCP       | VLAN-DMZ  | Mailjet_SMTP (`in-v3.mailjet.com`)                                                          | 587      | Allow SMTP                         | Yes |

📄 **References**:
- `vault_domains_allow_proxy.txt` contains all domain allowlists configured in the Squid proxy  
- [Cloudflare IP Ranges](https://www.cloudflare.com/ips/) are used to allow QUIC traffic

---

## 🛡️ CrowdSec Integration

CrowdSec is integrated into the Vaultwarden stack to provide active protection against brute-force and enumeration attacks by **automatically IP banning malicious actors**. Vaultwarden writes structured logs to `/logs/vaultwarden.log` using extended logging, and CrowdSec parses these logs in real time to detect authentication abuse.

This setup uses the [Vaultwarden collection by Dominic-Wagner](https://app.crowdsec.net/hub/author/Dominic-Wagner/collections/vaultwarden), which provides pre-configured scenarios for detecting common attack patterns against Vaultwarden instances. Ban decisions are enforced at the Cloudflare edge using the [Cloudflare Workers bouncer](https://docs.crowdsec.net/u/bouncers/cloudflare-workers/).

**References**:
- [Dominic-Wagner's Vaultwarden Collection](https://app.crowdsec.net/hub/author/Dominic-Wagner/collections/vaultwarden)
- [CrowdSec Cloudflare Workers Bouncer Documentation](https://docs.crowdsec.net/u/bouncers/cloudflare-workers/)
- [Dominic-Wagner on GitHub](https://github.com/Dominic-Wagner)

### **Vaultwarden Logging Configuration**

Vaultwarden is configured in `docker-compose.yml` with the following options:

* `/srv/vw-logs:/logs` as the dedicated log volume
* `EXTENDED_LOGGING=true`, `LOG_LEVEL=error`, and a consistent timestamp format
* Custom rate limits designed to complement CrowdSec:

```bash
ADMIN_RATELIMIT_MAX_BURST=10
ADMIN_RATELIMIT_SECONDS=300
RATELIMIT_MAX_BURST=100
RATELIMIT_SECONDS=60
```

This preserves Vaultwarden's own rate limits while allowing CrowdSec to evaluate larger windows of activity.

### **CrowdSec Scenarios for Vaultwarden**

Two custom CrowdSec scenarios are used to analyze the Vaultwarden log file:

#### **Brute Force Scenario** (`crowdsec-vaultwarden-bf.yaml`)

* **leakspeed**: 30m
* **capacity**: 20
* **blackhole**: 4h

This means an IP must generate more than 20 failed logins within a 30-minute window for CrowdSec to issue an IP ban.

#### **User Enumeration Scenario** (`crowdsec-vaultwarden-enum.yaml`)

* **leakspeed**: 30m
* **capacity**: 5
* **blackhole**: 30m

This detects attempts where a client tries multiple usernames consecutively.

### **Cloudflare Worker Bouncer**

CrowdSec is connected to Cloudflare through the official Cloudflare Worker bouncer. When CrowdSec creates a ban decision, the worker immediately propagates it to Cloudflare, so the block is enforced at the edge before any traffic reaches Vaultwarden.

### **Log Rotation**

The Vaultwarden log file (`/srv/vw-logs/vaultwarden.log`) is managed with logrotate to prevent unlimited growth while maintaining log history for CrowdSec analysis. Configuration is in `/etc/logrotate.d/vaultwarden`:

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

This rotates logs daily, keeps 3 days of history, compresses old logs, and uses `copytruncate` to avoid disrupting the running container.

---

## 🌐 Network and Proxy Configuration

Previously, domain access was restricted using firewall rules with domain allowlisting (`vault_domains_allow_firewall.txt`), but this approach was not reliable. I replaced this with a **dedicated Squid proxy** running in a separate VM on my Proxmox server.

### **Proxy Architecture**

* The Squid proxy VM is located on a **different VLAN** than the Raspberry Pi hosting Vaultwarden and CrowdSec
* The Raspberry Pi now communicates through Squid (192.168.173.9:3128) for outbound traffic control
* Domain allowlisting is managed via `vault_domains_allow_proxy.txt` and enforced by Squid using the configuration in `squid.conf`
* The `squid.conf` file implements a whitelist-only approach: allows access to domains in the allowlist file and blocks everything else
* This provides more predictable behavior than firewall-based domain filtering

### **System-Wide Proxy Configuration**

To route all outbound traffic through the Squid proxy, three configuration files must be created on the Raspberry Pi. Each file serves a specific purpose to ensure proxy variables are available in different contexts:

#### **1. `/etc/environment`**
This file sets proxy variables for the entire system so all programs launched normally inherit them. It applies to both root and regular users, but **not** to systemd services.

```bash
http_proxy="http://192.168.173.9:3128"
https_proxy="http://192.168.173.9:3128"
HTTP_PROXY="http://192.168.173.9:3128"
HTTPS_PROXY="http://192.168.173.9:3128"
NO_PROXY="localhost,127.0.0.1,::1,caddy,vaultwarden"
no_proxy="localhost,127.0.0.1,::1,caddy,vaultwarden"
```

#### **2. `/etc/systemd/system.conf.d/proxy.conf`**
Systemd does not read `/etc/environment`, so this file forces all systemd services to inherit the proxy variables. It ensures services started at boot use the proxy correctly.

```ini
[Manager]
DefaultEnvironment="HTTP_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="http_proxy=http://192.168.173.9:3128"

DefaultEnvironment="HTTPS_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="https_proxy=http://192.168.173.9:3128"

DefaultEnvironment="NO_PROXY=localhost,127.0.0.1,::1,caddy,vaultwarden"
DefaultEnvironment="no_proxy=localhost,127.0.0.1,::1,caddy,vaultwarden"
```

#### **3. `/etc/profile.d/proxy.sh`**
This file loads the proxy variables for interactive shells like SSH sessions. It ensures proxy variables exist when a user opens a shell and runs commands manually.

```bash
# System-wide proxy settings for interactive shells

export http_proxy="http://192.168.173.9:3128"
export https_proxy="http://192.168.173.9:3128"

export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

export no_proxy="localhost,127.0.0.1,::1,caddy,vaultwarden"
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

Vaultwarden and Caddy are added to the `no_proxy` list to ensure the Podman containers **do not send internal container-to-container traffic through Squid**. If they were not excluded, DNS and HTTP requests for these internal services would mistakenly go to the proxy, causing failures during container startup. This prevents loops and ensures Podman networks resolve them directly.

---

## 🐳 Container Startup and Podman User Configuration

Containers are now started by the dedicated Podman user (`poduser`) instead of root to prevent environment variable exposure during startup.

### **Container Launch Configuration**

* Containers are launched at boot using the `poduser` crontab with:
  ```bash
  @reboot /bin/bash -lc '/home/poduser/vault/start-containers.sh'
  ```
* The `start-containers.sh` script performs a few system checks before starting `podman-compose`:
  - waits for a default network route to be present
  - waits until `/etc/resolv.conf` contains at least one `nameserver`
  - optionally waits for DNS resolution (e.g., `cloudflare.com`) to succeed
  After these checks it runs `podman-compose up -d`.
* These checks ensure the containers start safely by verifying network and DNS availability.

### **Global Podman Compose Aliases**

To simplify container management while keeping output suppressed globally, helper aliases are available in `podman_compose_aliases.sh`:

```bash
pcup()    # podman-compose up -d
pcdown()  # podman-compose down
```

This file is sourced system-wide so any user managing Podman containers can use these aliases without exposing sensitive output.

---

## 🔐 Additional Security Layers

### **Security Headers**

The Caddy reverse proxy implements comprehensive HTTP security headers, achieving an **A+ rating** on [securityheaders.com](https://securityheaders.com).

#### **Implemented Headers**

| Header | Value | Source | Purpose |
|--------|-------|--------|---------|
| **`Strict-Transport-Security`** | `max-age=31536000; includeSubDomains; preload` | Caddy (global) | Enforces HTTPS for 1 year, including all subdomains. Prevents protocol downgrade attacks and cookie hijacking. Domain is [HSTS preloaded](https://hstspreload.org/) in browsers. |
| **`Content-Security-Policy`** | *(Vaultwarden default CSP for main app)* Strict policy for static files: `default-src 'none'; base-uri 'none'; frame-ancestors 'none'` | Vaultwarden + Caddy (static files only) | Vaultwarden sets a comprehensive CSP by default for the application. Caddy applies a stricter CSP specifically to `robots.txt` and `security.txt` files, preventing any resource loading or framing. |
| **`X-Content-Type-Options`** | `nosniff` | Caddy (global) | Prevents MIME type sniffing. Stops browsers from interpreting files as a different MIME type than declared, blocking potential XSS attacks. |
| **`X-Frame-Options`** | `SAMEORIGIN` | Vaultwarden + Caddy (static files only) | Prevents clickjacking attacks by disallowing the site from being embedded in iframes from other origins. Vaultwarden sets this by default; Caddy also applies it to static files. |
| **`Referrer-Policy`** | `same-origin` | Caddy (global) | Limits referrer information to same-origin requests only. Prevents leaking sensitive URLs (including tokens/IDs) to external sites. |
| **`Permissions-Policy`** | `accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), display-capture=(), document-domain=(), encrypted-media=(), execution-while-not-rendered=(), execution-while-out-of-viewport=(), fullscreen=(), geolocation=(), gyroscope=(), interest-cohort=(), magnetometer=(), microphone=(), midi=(), payment=(), picture-in-picture=(), screen-wake-lock=(), sync-xhr=(), usb=(), web-share=(), xr-spatial-tracking=()` | Caddy (global) | Disables 24 browser features that are unnecessary for a password manager, reducing attack surface. Notable: blocks FLoC tracking, sensor APIs, media capture, and geolocation. Clipboard and WebAuthn remain enabled for password management functionality. |
| **`Cross-Origin-Opener-Policy`** | `same-origin` | Caddy (global) | Isolates the browsing context, preventing other origins from interacting with your windows. Protects against Spectre-like attacks and cross-origin information leaks. |
| **`Cross-Origin-Resource-Policy`** | `same-origin` | Vaultwarden + Caddy (static files only) | Prevents other origins from loading resources from this site, protecting against certain cross-origin attacks. Vaultwarden sets this by default; Caddy also applies it to static files. |
| **`X-Robots-Tag`** | `noindex, nofollow` | Vaultwarden + Caddy (static files only) | Instructs search engines not to index or follow links. Vaultwarden applies this to the application; Caddy applies it specifically to `robots.txt` and `security.txt` files. |
| **`X-XSS-Protection`** | `0` | Vaultwarden + Caddy (static files only) | Disables the legacy XSS filter in older browsers, as modern CSP provides better protection and the old XSS filter can introduce vulnerabilities. Vaultwarden sets this by default; Caddy also applies it to static files. |

#### **Removed Headers**

| Header | Purpose |
|--------|---------|
| **`-Server`** | Removes server identification to prevent fingerprinting and targeted attacks based on known server vulnerabilities. |
| **`-Via`** | Removes proxy information that could reveal infrastructure details. |

#### **Why These Matter for Vaultwarden**

Password managers are high-value targets. These headers provide defense-in-depth:

- **HSTS + Preload**: Ensures connections are always encrypted, even before the first request
- **CSP + X-Frame-Options**: Prevents UI redressing attacks that could trick users into revealing passwords
- **Permissions-Policy**: Blocks unnecessary browser APIs that could be exploited (cameras, microphone, sensors)
- **COOP + Referrer-Policy**: Prevents cross-origin data leaks, including sensitive vault URLs
- **Server/Via removal**: Reduces information disclosure for potential attackers


---

### **Cloudflare**

* TLS **1.3 enforced** as the minimum version
* **Automatic HTTP → HTTPS redirection**
* **HSTS enabled** (max-age 12 months, include subdomains, preload)
* **Certificate Transparency Monitoring** to receive alerts on new certificate issuance
* **Full (strict) SSL/TLS** for end-to-end encryption with Let’s Encrypt ([Cloudflare docs](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/))
* **Opportunistic Encryption disabled** to avoid unintended HTTP requests
* **Geo-blocking** for specific countries (but `robots.txt` remains globally accessible)
* **RUM script disabled** to prevent Cloudflare analytics injection ([Cloudflare docs](https://developers.cloudflare.com/speed/speed-test/rum-beacon/))
* **Zero-trust admin access**:

  * Accessing `/admin` triggers a Cloudflare Access login page
  * Only my GitHub account is allowed, adding another layer of protection before the Vaultwarden password prompt
* **DNS CAA records enforced** to restrict certificate issuance to only trusted Certificate Authorities, preventing unauthorized SSL/TLS certificates for the domain
* **HSTS Preload enabled**: Submitted the domain to [hstspreload.org](https://hstspreload.org/) to ensure browsers enforce HSTS by default, providing stronger protection against downgrade attacks.
* **DNSSEC enabled**: The domain uses DNSSEC (Domain Name System Security Extensions) to cryptographically sign DNS records, protecting against DNS spoofing and ensuring the authenticity of DNS responses.

---

### **Vaultwarden Configuration**

* **Icon fetching disabled**: Vaultwarden can normally fetch favicons from the domains of saved logins.

  * This feature is disabled to prevent outbound requests to arbitrary websites, simplify firewall rules, and reduce external visibility of the instance.
  * The environment variable **`ICON_CACHE_TTL=0`** is set so that previously downloaded icons remain served locally without refresh or re-fetch, while no new outbound requests are made.

* **Sends disabled**: The optional Sends feature for file and note sharing is not required in this setup.

  * Disabling it removes functionality that is unnecessary for the intended use case and also reduces potential attack surface.

* **Signups and invitations disabled**: Vaultwarden allows new user registrations and user-to-user invitations by default.

  * These options are disabled in the provided `docker-compose.yml` to prevent unauthorized account creation and maintain strict control over access.
  * No additional configuration is required by the user, this setup already applies the restriction.

---

### **Backup and Redundancy**

Backups are encrypted using [age](https://github.com/FiloSottile/age), a modern public-key encryption tool that replaces the previous OpenSSL-based hybrid encryption. This change was made because system updates can silently change OpenSSL behavior and defaults, making old backups difficult to decrypt. The backup system is designed to be **reproducible**, **self-contained**, and **future-proof**:

* **[Key Pair Generation](#-age-key-pair-generation)** for creating age keys on a separate machine (private key never on the VM)
* **[`setup-age.sh` Usage](#-setup-agesh-usage)** for downloading and pinning age binaries from GitHub releases
* **[Decrypting a Backup](#-decrypting-a-backup)** for step-by-step restore instructions (Linux + Windows)
* **[Updating age](#-updating-age)** for safely upgrading to newer versions without breaking old backups

#### **Design Principles**

* **Self-contained bundles**: Every backup bundle includes the exact age binaries (Linux + Windows) used for encryption, a manifest with checksums, and decryption instructions. You only need the private key to decrypt.
* **Pinned binaries**: age is not installed via `apt`. Instead, a specific version is downloaded from GitHub releases and stored at `/srv/tools/age/{version}/`. System updates cannot silently change the encryption tool.
* **Version control**: Old age binaries are never removed. `main.sh` references a specific `AGE_VERSION` that you update manually after downloading a new version with `setup-age.sh`.
* **Public-key only on the server**: The VM only has the recipient public key (`age1...`). The private key (identity file) is generated and stored on a separate machine, never on the backup server.
* **Update awareness**: Each backup run checks GitHub for newer age releases and logs a warning, but never auto-updates.

#### **Backup Bundle Structure**

Each daily backup produces a self-contained bundle:

```
vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz
├── vw-data-backup-YYYY-MM-DD.tar.gz.age   # age-encrypted backup archive
├── age                                      # age binary (Linux amd64)
├── age.exe                                  # age binary (Windows amd64)
├── manifest-YYYY-MM-DD.txt                  # checksums + metadata
└── DECRYPT.txt                              # step-by-step decryption instructions
```

The manifest records:
* `age_version` — the pinned version used (e.g., `v1.3.1`)
* `archive_sha256` — SHA-256 of the encrypted archive
* `age_binary_sha256` — SHA-256 of the included Linux age binary
* `age_binary_win_sha256` — SHA-256 of the included Windows age binary
* `recipient_public_key` — the full `age1...` public key
* `timestamp` — backup creation time (UTC)

#### **Replication**

* Daily replication to **TrueNAS (local)** and **Hetzner Storage Box (cloud)** via `truenas-script.sh`
* Restricted SSH user for backup access, limiting exposure

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

5. Transfer `age-recipient.txt` to the Vaultwarden VM:
   ```
   scp -P 2222 age-recipient.txt user@vm-host:/srv/age-recipient.txt
   ```

6. Store `identity.txt` securely offline (USB drive, encrypted storage, or a separate secure machine). This is the **only** file that can decrypt your backups.

---

### 📦 **`setup-age.sh` Usage**

This script downloads and pins [age](https://github.com/FiloSottile/age) binaries (both Linux and Windows) from GitHub releases into versioned directories. It is used for the initial setup and for downloading newer versions when you choose to update. Old versions are **never** removed.

#### **Commands**

```bash
# Download the latest release from GitHub
./setup-age.sh

# Download a specific version
./setup-age.sh v1.3.1
```

If no version is specified, the script queries the [GitHub API](https://api.github.com/repos/FiloSottile/age/releases/latest) to determine the latest release automatically.

#### **What It Does**

1. Resolves the target version (from argument or GitHub API)
2. Checks if that version is already downloaded — skips if so
3. Downloads both `age-{version}-linux-amd64.tar.gz` and `age-{version}-windows-amd64.zip` from GitHub releases
4. Extracts `age`, `age-keygen`, `age.exe`, and `age-keygen.exe` into `/srv/tools/age/{version}/`
5. Computes and stores SHA-256 checksums for all binaries
6. Prints a summary with checksums and a reminder to update `AGE_VERSION` in `main.sh`

#### **Directory Layout**

After running `./setup-age.sh v1.3.1`:

```
/srv/tools/age/
└── v1.3.1/
    ├── age                  # Linux amd64 binary
    ├── age.sha256
    ├── age-keygen           # Linux keygen (included from tarball)
    ├── age-keygen.sha256
    ├── age.exe              # Windows amd64 binary
    ├── age.exe.sha256
    ├── age-keygen.exe       # Windows keygen (included from zip)
    └── age-keygen.exe.sha256
```

Multiple versions can coexist side by side:

```
/srv/tools/age/
├── v1.3.0/                  # older version, kept in place
│   └── ...
└── v1.3.1/                  # current version
    └── ...
```

#### **After Downloading a New Version**

The script only downloads — it does **not** activate the new version automatically. To start using it for backups, manually update the version string in `main.sh`:

```bash
AGE_VERSION="v1.3.1"
```

This deliberate step ensures you are always in control of which version encrypts your backups.

---

### 🔓 **Decrypting a Backup**

Each backup bundle is **self-contained** and includes age binaries for both Linux and Windows. See `DECRYPT.txt` (included in every bundle) for detailed step-by-step instructions.

#### **1. Extract the Bundle**

```bash
tar xzf vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz
```

On Windows, use `tar` in PowerShell, or extract with 7-Zip / WinRAR.

#### **2. Verify Checksums** *(optional but recommended)*

Check the values in `manifest-YYYY-MM-DD.txt` against the actual files:

**Linux / macOS**:
```bash
sha256sum vw-data-backup-YYYY-MM-DD.tar.gz.age
sha256sum age
```

**Windows (PowerShell)**:
```powershell
Get-FileHash vw-data-backup-YYYY-MM-DD.tar.gz.age -Algorithm SHA256
Get-FileHash age.exe -Algorithm SHA256
```

#### **3. Decrypt**

**Linux / macOS**:
```bash
chmod +x age
./age -d -i /path/to/identity.txt -o vw-data-backup-YYYY-MM-DD.tar.gz vw-data-backup-YYYY-MM-DD.tar.gz.age
```

**Windows (PowerShell / CMD)**:
```
.\age.exe -d -i C:\path\to\identity.txt -o vw-data-backup-YYYY-MM-DD.tar.gz vw-data-backup-YYYY-MM-DD.tar.gz.age
```

Replace the identity path with the actual path to your age private key.

#### **4. Extract the Decrypted Archive**

```bash
tar xzf vw-data-backup-YYYY-MM-DD.tar.gz
```

This restores the Vaultwarden data directory contents.

---

### 🔄 **Updating age**

To update to a newer age version:

1. On the Vaultwarden VM, run:
   ```bash
   ./setup-age.sh          # downloads latest
   # or
   ./setup-age.sh v1.4.0   # downloads specific version
   ```

2. Update `AGE_VERSION` in `main.sh`:
   ```bash
   AGE_VERSION="v1.4.0"
   ```

The old version remains at `/srv/tools/age/{old-version}/` and is never deleted. Previous backups still include the exact binaries they were encrypted with.
