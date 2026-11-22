# OPNsense firewall

The firewall / router box, on its own hardware, separate from the [Proxmox host](../proxmox/README.md). Running bare metal means a Proxmox reboot or crash never takes the network down with it.

This page only covers the box itself: hardware, OS and plugins. How its block log reaches Wazuh and Discord is in [`Vaultwarden/wazuh-home/opnsense/`](../Vaultwarden/wazuh-home/opnsense/README.md).

---

## Hardware

| Part | What's in it |
| --- | --- |
| **Machine** | Lenovo ThinkCentre M710q Tiny |
| **CPU** | Intel Core i5-7400T, 4 cores / 4 threads (2.4 GHz, 35 W), AES-NI active |
| **RAM** | 16 GB DDR4-2400 (2× 8 GB Crucial SO-DIMM, both channels) |
| **Storage** | 1× Micron 2200 256 GB NVMe (`MTFDHBA256TDV`) |
| **NICs** | 2× gigabit Intel, see the table below |

| Port | Chip | Where | FreeBSD name | Used as |
| --- | --- | --- | --- | --- |
| 1 | Intel I219-V | onboard | `em0` | **WAN** |
| 2 | Intel I210 | M.2 A+E key adapter (KALEA-INFORMATIQUE), in the Wi-Fi card's slot | `igb0` | **LAN** |

AES-NI matters on a firewall: it's what keeps AES-based VPNs (IPsec, OpenVPN) and TLS cheap on a 35 W CPU. WireGuard, and so Tailscale, uses ChaCha20 instead and doesn't need it. OPNsense uses it once the `aesni` module is loaded; the supported modes show up under `sysctl dev.aesni.0.%desc`.

The M710q Tiny has only one Ethernet port and no PCIe slot (without Lenovo's riser), so the second port comes from the M.2 A+E slot meant for the Wi-Fi card: a small adapter with an Intel I210 on it and its RJ45 port on a short cable. Both NICs are Intel, on purpose: FreeBSD's Intel drivers (`em` for the I219, `igb` for the I210) are the most solid ones, Realtek cards are the usual source of drops and odd link problems on OPNsense.

---

## Software

- **OPNsense** on FreeBSD, installed on UFS (single disk, journaled soft-updates).
- **Single disk, no mirror.** If the NVMe dies the box goes down until it's replaced, so the config is what has to survive: `os-git-backup` pushes every config change to a private repo on a self-hosted Forgejo running on TrueNAS, and a reinstall + config import gets the box back.
- **CPU microcode** comes from `os-cpu-microcode-intel`, loaded at boot, so the i5 gets Intel's security fixes without waiting for a BIOS update.

Installed plugins:

| Plugin | What for |
| --- | --- |
| `os-cpu-microcode-intel` | Intel CPU microcode updates at boot |
| `os-dmidecode` | hardware info (RAM, board) in the GUI |
| `os-git-backup` | config backup on every change, pushed to self-hosted Forgejo on TrueNAS |
| `os-isc-dhcp` | ISC DHCP server |
| `os-tailscale` | Tailscale |
