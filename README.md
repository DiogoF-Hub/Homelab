# Homelab

This repository contains my personal **homelab configurations and scripts** for services like **Vaultwarden**, **Pi-hole**, and **custom HTTPS certificate generation**. It includes everything from Docker Compose files to automation scripts that make deploying, updating, and maintaining these services much easier.

The goal is to **share my setup publicly** so others can learn, adapt, or get inspiration for their own homelab environments. The only thing I kindly ask is that if you find something that could improve security or make the setup better, please let me know so I can learn and improve as well.

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
├── Vaultwarden/
│   ├── .env
│   ├── Caddyfile
│   ├── README.md
│   ├── certbot.conf
│   ├── docker-compose.yml
│   ├── main.sh
│   ├── robots.txt
│   ├── security.txt
│   ├── root_crontab.txt
│   ├── start-containers.sh
│   ├── truenas-script.sh
│   ├── deploy-hook.sh
│   ├── vault_domains_allow_firewall.txt
│
└── HTTPS Generator/
  ├── README.md
  ├── generate_cert.sh
  ├── openssl.cnf
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

### **HTTPS Generator**

* **Features**

  * Creates a **root CA** for signing device certificates
  * Generates **device-specific certificates** with proper SAN support

    * Hostname, `.local`, `.localdomain`, and optional **Tailscale domains**
    * Optional IP entries
  * Certificates are **iOS-compatible**, respecting the 825-day limit
* **Usage**

  * `generate_cert.sh` to create certificates for services or devices
  * `openssl.cnf` template automatically customized by the script
  * Root CA (`rootCA.pem`) can be installed on devices (rename to `.crt` if needed)

---

## 🚀 Goals

* Keep configurations version-controlled and organized
* Share a reproducible and secure setup for self-hosted services
* Create a well-documented setup that is easy to manage and evolve as I learn and improve my homelab.

---

## ⚠️ Disclaimer

These configurations are tailored to my environment.
Before using them, **review and customize** for your own domain, network, and security settings.
