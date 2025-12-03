# Vaultwarden Setup

This folder contains my **Vaultwarden configuration and automation scripts**, originally based on **Docker** but now progressively migrating to **Podman**.

I’ve made a **full switch to running containers with [Podman](https://podman.io/)** for better security and system integration.
A **dedicated non-privileged user** (`poduser`) is used to run Podman containers.

However, **Docker remains installed** on the system to use certain commands, such as:

```bash
docker compose config --services
````

This allows me to easily list the services in a compose file without affecting container runtime.

The setup is designed for **secure self-hosted password management**, with:

* **[Caddy reverse proxy](#caddy-reverse-proxy-caddyfile)** for HTTPS, security headers, a `robots.txt` file, and a `security.txt` file for vulnerability reporting
* **[CrowdSec integration](#%EF%B8%8F-crowdsec-integration)** for active protection with automatic IP banning of malicious actors
* **[Squid proxy](#-network-and-proxy-configuration)** for reliable outbound domain allowlisting and traffic control
* **Encrypted backups** using hybrid encryption
* **Automated off-site replication** to TrueNAS and Hetzner Storage Box
* **Strict [Cloudflare](#cloudflare) security policies** for zero trust access
* **Full network isolation** by running on a dedicated VLAN with [strict firewall rules in OPNsense](#-dmz-firewall-rules)
* **Hosted on a Raspberry Pi**, keeping the service lightweight and energy-efficient

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
└── README.md                         # This documentation
```

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

This file defines the core variables for your setup.
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

* Provides **HTTPS** for Vaultwarden
* Implements **comprehensive security headers** (see [Security Headers](#-additional-security-layers) section for full details)
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
* Docker is kept installed to use convenient `docker compose` commands (like `config --services`).
* A dedicated non-root user (`poduser`) runs Podman containers, improving security.

---

## 🔄 Automation Scripts

| Script                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`start-containers.sh`** | Brings up Vaultwarden and Caddy after a reboot (run via `poduser` crontab with silent output).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **`main.sh`**             | Full daily maintenance script:<br>1. Stops containers safely<br>2. Creates an **encrypted backup** using hybrid encryption:<br>   • Generates a random AES-256 key<br>   • Encrypts the backup with AES-256<br>   • Encrypts that AES-256 key with a public key<br>   • Records the OpenSSL version used by running `openssl version -a` and saves the output to a `.txt` file<br>   • Packages the encrypted key, the backup, and the OpenSSL version file together into a compressed archive<br>3. Updates images<br>4. Runs a full system update and **does a reboot**. |
| **`truenas-script.sh`**   | Runs on TrueNAS to fetch daily encrypted backups and logs via `scp` using a restricted SSH user. After fetching locally, it pushes a copy to the **Hetzner Storage Box**, ensuring redundancy:<br>• Local backups on TrueNAS<br>• Cloud backups on Hetzner                                                                                                                                                                                                                                                                                                                 |
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
| 5 | Pass   | UDP       | VLAN-DMZ  | [Cloudflare_IPs](https://www.cloudflare.com/ips/)                                          | any-7844 | Allow QUIC from Cloudflare         | Yes |
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

#### **Critical: `no_proxy` Configuration**

Vaultwarden and Caddy are added to the `no_proxy` list to ensure the Raspberry Pi and Podman containers **do not send internal container-to-container traffic through Squid**. If they were not excluded, DNS and HTTP requests for these internal services would mistakenly go to the proxy, causing failures during container startup. This prevents loops and ensures Podman networks resolve them directly.

---

## 🐳 Container Startup and Podman User Configuration

Containers are now started by the dedicated Podman user (`poduser`) instead of root to prevent environment variable exposure during startup. When `podman-compose` expands the compose file into raw Podman run commands, sensitive information could leak into logs.

### **Container Launch Configuration**

* Containers are launched at boot using the `poduser` crontab with:
  ```bash
  @reboot /bin/bash -lc '/home/poduser/vault/start-containers.sh'
  ```
* The `start-containers.sh` script invokes `podman-compose up -d` and redirects all output to `/dev/null`
* This ensures expanded Podman commands and environment variables never appear in logs or system journals

### **Global Podman Compose Aliases**

To simplify container management while keeping output suppressed globally, helper aliases are available in `podman_compose_aliases.sh`:

```bash
pcup()    # podman-compose up -d (silent)
pcdown()  # podman-compose down (silent)
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
| **`X-Robots-Tag`** | `noindex, nofollow` | Caddy (static files only) | Instructs search engines not to index or follow links in `robots.txt` and `security.txt` files. |
| **`X-XSS-Protection`** | `0` | Caddy (static files only) | Disables the legacy XSS filter in older browsers, as modern CSP provides better protection and the old XSS filter can introduce vulnerabilities. |

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

* **Hybrid encryption** for every backup
* Daily replication to **TrueNAS (local)** and **Hetzner Storage Box (cloud)**
* Restricted SSH user for backup access, limiting exposure
