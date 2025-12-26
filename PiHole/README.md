# Pi-hole Setup

This folder contains my **Docker-based Pi-hole configuration and automation scripts**.
The setup is designed for **network-wide ad blocking**, **Cloudflare 1.1.1.3 DNS filtering**, and a **secure HTTPS-only web interface**.

Everything here is public for transparency and to help others learn, but you **must adapt the configuration to your own environment** before using it.

---

## 📂 Structure

```
PiHole/
├── .env                      # Required environment variable(s)
├── blocklist.txt             # Custom blocklists (user-defined)
├── cookielist_whitelist.txt  # Cookie consent platform whitelist
├── docker-compose.yml        # Docker Compose configuration
├── main.sh                   # Maintenance/update script (run via crontab everyday)
├── manual_domains_block.txt  # Custom manually blocked domains
├── mycustom_list.txt         # Additional custom blocked domains
├── root_crontab.txt          # Crontab entries for automation
├── start-containers.sh       # Startup script (run via crontab at boot)
└── README.md                 # This documentation
```

---

## ⚙️ Configuration Overview

### **Environment (`.env`)**

Only one required variable:

```bash
FTLCONF_webserver_api_password=YourStrongPassword
```

Optional adjustments like network bindings can be added if needed.

---

### **Docker Compose (`docker-compose.yml`)**

* Runs Pi-hole with:

  * Persistent volumes
  * Port `443` for the web interface (`FTLCONF_webserver_port='443s'`)
  * Cloudflare DNS **1.1.1.3** for malware and adult content filtering
* Easily extendable for advanced setups (VLAN integration, reverse proxy, etc.).

---

### **Custom User Files**

* **`blocklist.txt`** – Individually blocklists links to be added manually.
* **`cookielist_whitelist.txt`** – Cookie consent management platform (CMP) domains to whitelist, preventing cookie banners from breaking.
* **`manual_domains_block.txt`** – Individually domains to be added manually.
* **`mycustom_list.txt`** – Additional custom blocked domains list.
* **`root_crontab.txt`** – Contains the exact crontab entries to:

  * Start containers at boot (`start-containers.sh`).
  * Run maintenance and updates (`main.sh`) on a schedule every day.

---

### **Scripts**

| Script                    | Purpose                                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| **`start-containers.sh`** | Automatically starts Pi-hole after a reboot. Intended to be triggered via **root crontab**. |
| **`main.sh`**             | Handles gravity updates, updates the instances (docker images) and full system update. It creates 3 log files for each action. Also run automatically via **root crontab**.     |

---

## 🚀 Deployment Steps

1. **Set your password**
   Edit `.env`:

   ```bash
   FTLCONF_webserver_api_password=YourStrongPassword
   ```

2. **Load crontab entries**
   Open root crontab:

   ```bash
   sudo crontab -e
   ```

   Then paste the contents of `root_crontab.txt`.

3. **Start containers manually (first run only)**

   ```bash
   docker compose up -d
   ```

4. **Access the web interface**

   * URL: `https://pi.hole/admin`
   * Password: Use the one from `.env`.

5. **Add blocklists, domains, and whitelist**
   Add the blocklists, domains, and whitelist manually:
   * Add blocklists from `blocklist.txt`.
   * Add custom blocked domains from `manual_domains_block.txt` and `mycustom_list.txt`.
   * Add whitelisted domains from `cookielist_whitelist.txt` to prevent cookie consent banners from breaking.

---

## 🔒 Security Features

* **HTTPS-only** access on port 443.
* DNS routing through **Cloudflare 1.1.1.3** for security and filtering.
* Automated updates and restarts using crontab to reduce manual work.
