# Homelab

This repository contains my personal **homelab configurations and scripts** for services like **Vaultwarden**, **Pi-hole** and others. It includes everything from Docker Compose files to automation scripts that make deploying, updating, and maintaining these services much easier.

The goal is to **share my setup publicly** so others can learn, adapt, or get inspiration for their own homelab environments.

---

## 📂 Repository Structure

```
Homelab/
├── PiHole/
│   ├── .env
│   ├── README.md
│   ├── blocklist.txt
│   ├── docker-compose.yml
│   ├── main.sh
│   ├── manual_domains_block.txt
│   ├── root_crontab.txt
│   ├── start-containers.sh
│
└── Vaultwarden/
    ├── .env
    ├── Caddyfile
    ├── README.md
    ├── certbot.conf
    ├── docker-compose.yml
    ├── main.sh
    ├── robots.txt
    ├── root_crontab.txt
    ├── start-containers.sh
    ├── truenas-script.sh
```

---

## 🛠 Services

### **Pi-hole**

* **Features**

  * Network-wide ad and tracker blocking
  * DNS over HTTPS (DoH) support with Cloudflare
  * Custom blocklists and manual domain blocking
* **Scripts**

  * `main.sh` for maintenance tasks
  * `start-containers.sh` to bring services up
  * `root_crontab.txt` for automated scheduling

---

### **Vaultwarden**

* **Features**

  * Self-hosted password manager
  * Reverse-proxied with **Caddy** and HTTPS enabled
  * Cloudflare Tunnel-ready configuration
* **Scripts**

  * `main.sh` for updates and maintenance
  * `start-containers.sh` for container startup
  * `truenas-script.sh` for automated backups to TrueNAS
  * `root_crontab.txt` for automated tasks

---

## 🚀 Goals

* Keep configurations version-controlled and organized
* Share a reproducible and secure setup for self-hosted services
* Provide automation to simplify updates and backups

---

## ⚠️ Disclaimer

These configurations are tailored to my environment.
Before using them, **review and customize** for your own domain, network, and security settings.
