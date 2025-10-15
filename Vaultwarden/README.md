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

* **[Caddy reverse proxy](#caddy)** for HTTPS, security headers, a `robots.txt` file, and a `security.txt` file for vulnerability reporting
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
├── docker-compose.yml                # Compose configuration (used by Podman + Docker for parsing)
├── main.sh                           # Daily maintenance and update script
├── robots.txt                        # Disallows bots from indexing sensitive paths
├── security.txt                      # Contact info for reporting vulnerabilities (served at /.well-known/security.txt)
├── root_crontab.txt                  # Crontab entries for automation
├── start-containers.sh               # Startup script (run at boot via crontab)
├── vault_domains_allow_firewall.txt  # List of domains allowed for the firewall VLAN interface
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

> To generate the `ADMIN_TOKEN` hash, run this command inside the Vaultwarden container:
>
> ```bash
> podman exec -it vaultwarden /vaultwarden hash
> ```
>
> Then type your desired admin password, copy the output hash, and paste it into the `ADMIN_TOKEN` field in your `.env` file.

> Replace these values to match your environment and email provider.

---

### **Caddy Reverse Proxy (`Caddyfile`)**

* Provides **HTTPS** for Vaultwarden
* Hosts a `robots.txt` file (Vaultwarden does not natively support it)
* Hosts a `security.txt` file at `/.well-known/security.txt` to provide contact information for vulnerability reporting (see [security.txt standard](https://securitytxt.org/))

---

### **Certbot Configuration (`certbot.conf`)**

* Uses the **Cloudflare DNS plugin** with an API token to:

  * Automatically update DNS records
  * Request and renew Let’s Encrypt certificates
* Ensures **Full (strict) SSL/TLS** encryption between Cloudflare and the server

---

### **Podman + Docker Compose**

* Podman is used to **run all containers** in production.
* Docker is kept installed to use convenient `docker compose` commands (like `config --services`).
* A dedicated non-root user (`poduser`) runs Podman containers, improving security.

---

## 🔄 Automation Scripts

| Script                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`start-containers.sh`** | Brings up Vaultwarden and Caddy after a reboot (run via root crontab).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| **`main.sh`**             | Full daily maintenance script:<br>1. Stops containers safely<br>2. Creates an **encrypted backup** using hybrid encryption:<br>   • Generates a random AES-256 key<br>   • Encrypts the backup with AES-256<br>   • Encrypts that AES-256 key with a public key<br>   • Records the OpenSSL version used by running `openssl version -a` and saves the output to a `.txt` file<br>   • Packages the encrypted key, the backup, and the OpenSSL version file together into a compressed archive<br>3. Updates images<br>4. Runs a full system update and **does a reboot**. |
| **`truenas-script.sh`**   | Runs on TrueNAS to fetch daily encrypted backups and logs via `scp` using a restricted SSH user. After fetching locally, it pushes a copy to the **Hetzner Storage Box**, ensuring redundancy:<br>• Local backups on TrueNAS<br>• Cloud backups on Hetzner                                                                                                                                                                                                                                                                                                                 |
| **`deploy-hook.sh`**      | Certbot deploy hook: **copies renewed certificates to a directory accessible by `poduser`** and **restarts the Caddy server** to apply the new certificates.                                                                                                                                                                                                                                                                                                                                                                                                               |

---

## 🚀 Deployment Steps

1. **Edit environment variables**
   Update `.env` with your domain, admin token, and SMTP details.

2. **Configure Cloudflare for DNS and certificates**

   * Generate a Cloudflare API token with DNS edit permissions
   * Create a Zero Trust token for Cloudflare Access and configure it to route `https://caddy`
   * Add your API token to `certbot.conf` for automatic certificate renewals

3. **Load crontab entries**

   ```bash
   sudo crontab -e
   ```

   Paste the contents of `root_crontab.txt`.

4. **Start containers manually (first run only)**

   ```bash
   podman-compose up -d
   ```

5. **Access the web interface**

   * URL: `https://<your-domain>`

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
| 1 | Block  | Any       | VLAN-DMZ  | (Any other VLANs)                                                                           | Any      | Block DMZ to other VLANs           | Yes |
| 2 | Pass   | TCP/UDP   | VLAN-DMZ  | DNS_Providers (Cloudflare and Quad9)                                                        | 53       | Allow DNS                          | Yes |
| 3 | Pass   | TCP/UDP   | VLAN-DMZ  | Vaultwarden_Allow (`vault_domains_allow_firewall.txt`), Git Section of [GitHub_IPs](https://api.github.com/meta) | 443      | Allow HTTPS in VLAN-DMZ           | Yes |
| 4 | Pass   | TCP/UDP   | VLAN-DMZ  | Vaultwarden_Allow (`vault_domains_allow_firewall.txt`), Git Section of [GitHub_IPs](https://api.github.com/meta) | 80       | Allow HTTP in VLAN-DMZ            | Yes |
| 5 | Pass   | UDP       | VLAN-DMZ  | This Firewall                                                                              | 123      | Allow NTP                          | Yes |
| 6 | Pass   | TCP/UDP   | VLAN-DMZ  | [Cloudflare_IPs](https://www.cloudflare.com/ips/)                                          | any-7844 | Allow QUIC from Cloudflare         | Yes |
| 7 | Pass   | TCP       | VLAN-DMZ  | Mailjet_SMTP (`in-v3.mailjet.com`)                                                          | 587      | Allow SMTP                         | Yes |

📄 **References**:
- `vault_domains_allow_firewall.txt` contains all domain allowlists for the Vaultwarden container  
- [GitHub IPs API](https://api.github.com/meta) is used to maintain allowlists for Git connections  
- [Cloudflare IP Ranges](https://www.cloudflare.com/ips/) are used to allowed QUIC traffic

---

## 🔐 Additional Security Layers

### **Caddy**

* Forces HTTPS
* Adds strong security headers:

  ```bash
  header {
      # HSTS with preload
      Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"

      # Prevent MIME type sniffing
      X-Content-Type-Options "nosniff"

      # Limit referrer information to same-origin only
      Referrer-Policy "same-origin"

      # Disable Google's FLoC tracking
      Permissions-Policy "interest-cohort=()"

      # Hide server information
      -Server
  }
  ```
* Provides `robots.txt` to block indexing of sensitive paths
* **Added `security.txt`**: Implements the [security.txt standard](https://securitytxt.org/) to provide clear contact information for reporting vulnerabilities or security issues. This file is served via Caddy at `/.well-known/security.txt`, helping security researchers reach out responsibly and improving overall transparency.

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
