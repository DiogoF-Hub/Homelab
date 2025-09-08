# Vaultwarden Setup

This folder contains my **Docker-based Vaultwarden configuration and automation scripts**.
The setup is designed for **secure self-hosted password management**, with:

* **Caddy reverse proxy** for HTTPS, security headers, a `robots.txt` file, and a `security.txt` file for vulnerability reporting
* **Encrypted backups** using hybrid encryption
* **Automated off-site replication** to TrueNAS and Hetzner Storage Box
* **Strict Cloudflare security policies** for zero trust access
* **Full network isolation** by running on a dedicated VLAN with strict firewall rules in OPNsense
* **Hosted on a Raspberry Pi**, keeping the service lightweight and energy-efficient

Everything here is public for transparency and to help others learn, but you **must adapt the configuration to your own environment** before using it.

---

## 📂 Structure

```
Vaultwarden/
├── .env                      # Environment variables
├── Caddyfile                 # Caddy reverse-proxy configuration (HTTPS, headers, robots.txt)
├── certbot.conf              # Certbot DNS configuration for Cloudflare
├── docker-compose.yml        # Docker Compose configuration
├── main.sh                   # Daily maintenance and update script
├── robots.txt                # Disallows bots from indexing sensitive paths
├── security.txt              # Contact info for reporting vulnerabilities (served at /.well-known/security.txt)
├── root_crontab.txt          # Crontab entries for automation
├── start-containers.sh       # Startup script (run at boot via crontab)
├── truenas-script.sh         # Script on TrueNAS to pull backups and logs
└── README.md                 # This documentation
```

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

This file defines the core variables for your setup.
Example template:

```bash
ADMIN_TOKEN=''         # admin panel token (must be generated inside the Vaultwarden Docker image because it outputs a password hash)
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
I used [Mailjet](https://www.mailjet.com) provider

> To generate the `ADMIN_TOKEN` hash, run this command inside the Vaultwarden container:
>
> ```bash
> docker exec -it vaultwarden /vaultwarden hash
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
* Ensures **Full (strict) SSL/TLS** encryption between Cloudflare and your server

---

### **Docker Compose (`docker-compose.yml`)**

* Runs Vaultwarden with persistent volumes
* Uses Caddy as the reverse proxy
* Cloudflare Tunnel for external access

---

## 🔄 Automation Scripts

| Script                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`start-containers.sh`** | Brings up Vaultwarden and Caddy after a reboot (run via root crontab).                                                                                                                                                                                                                                                                                                                                                                                           |
| **`main.sh`**             | Full daily maintenance script:<br>1. Stops containers safely<br>2. Creates an **encrypted backup** using hybrid encryption:<br>   • Generates a random AES-256 key<br>   • Encrypts the backup with AES-256<br>   • Encrypts that AES-256 key with a public key<br>   • Packages both encrypted key and backup into a compressed archive<br>3. Updates Docker images<br>4. Runs a full system update and **does a reboot**. |
| **`truenas-script.sh`**   | Runs on TrueNAS to fetch daily encrypted backups and logs via `scp` using a restricted SSH user. After fetching locally, it pushes a copy to the **Hetzner Storage Box**, ensuring redundancy:<br>• Local backups on TrueNAS<br>• Cloud backups on Hetzner                                                                                                                                                                                                       |

---

## 🚀 Deployment Steps

1. **Edit environment variables**
   Update `.env` with your domain, admin token, and SMTP details.

2. **Configure Cloudflare for DNS and certificates**

   * Generate a Cloudflare API token with DNS edit permissions
   * Create a Zero Trust token for Cloudflare Access and configure it to route `https://caddy` (Docker internal DNS will resolve it)
   * Add your API token to `certbot.conf` for automatic certificate renewals

3. **Load crontab entries**

   ```bash
   sudo crontab -e
   ```

   Paste the contents of `root_crontab.txt`.

4. **Start containers manually (first run only)**

   ```bash
   docker compose up -d
   ```

5. **Access the web interface**

   * URL: `https://<your-domain>`

---

## 🔒 Security Features

### **Caddy**

* Forces HTTPS
* Adds strong security headers:

  ```bash
  header {
      # HSTS with preload
      Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

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

### **Backup and Redundancy**

* **Hybrid encryption** for every backup
* Daily replication to **TrueNAS (local)** and **Hetzner Storage Box (cloud)**
* Restricted SSH user for backup access, limiting exposure
