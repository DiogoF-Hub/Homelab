# Proxmox host

The Proxmox VE node the VMs in this repo run on: a single node with the OS and all VM disks on a ZFS mirror of two NVMe SSDs. The firewall (OPNsense) is not on it, it runs on its own separate box.

Clean shutdown and VM start order (guest agent, shutdown hooks, `--startup order`) are in the top-level [README](../README.md), section "Proxmox: clean shutdown and start order".

---

## Hardware

| Part | What's in it |
| --- | --- |
| **Machine** | Lenovo ThinkStation P500 |
| **CPU** | 1× Intel Xeon E5-2699 v3, 18 cores / 36 threads (2.3 GHz base, 3.6 GHz turbo), SMT on |
| **RAM** | 48 GB DDR4-2133 ECC registered (SK Hynix): 2× 16 GB + 2× 8 GB in DIMM_1-4, DIMM_5-8 free |
| **Boot / VM storage** | 2× Crucial T500 1 TB NVMe (`CT1000T500SSD8`), ZFS mirror `rpool` |
| **Bulk storage** | 2× Seagate IronWolf 4 TB SATA HDD (`ST4000VN006`), passed through to the TrueNAS VM |
| **GPU** | NVIDIA NVS 510 (display output only) |

---

## Storage layout

```
rpool (ZFS mirror, 2× 1 TB NVMe)
  mirror-0
    nvme0n1p3
    nvme1n1p3
```

- **`rpool`** holds the Proxmox OS (`/`) and every VM disk. Mirror = either SSD can die and the host keeps running; replace the dead one and resilver.
- **Both NVMe drives are bootable.** The PVE installer puts an EFI partition on each mirror disk and `proxmox-boot-tool` keeps them in sync, so the host still boots (UEFI) if the first SSD is the one that died.
- **Swap is off.** Normal for a ZFS root: swap on a zvol can deadlock under memory pressure.
- **The HDDs never touch `rpool`.** They belong to TrueNAS, which runs its own pool on them.

Proxmox storage entries:

| Name | Type | Used for |
| --- | --- | --- |
| `local` | dir (on `rpool`) | ISO images, container templates |
| `local-zfs` | zfspool (on `rpool`) | VM disks (zvols) |

### ZFS ARC limit

ZFS uses spare RAM as a read cache (the ARC), and by default it can grow to half the RAM. On a VM host that RAM is better spent on the VMs, so the ARC is capped at **3 GiB**:

```bash
# /etc/modprobe.d/zfs.conf
options zfs zfs_arc_max=3221225472
```

After changing it: `update-initramfs -u -k all` and reboot (or write the value to `/sys/module/zfs/parameters/zfs_arc_max` to apply it live). Check with `pve-overview` (ZFS ARC line) or `arc_summary`.

---

## CPU affinity (SMT side channels)

SMT stays on, and the CPU leaks data between the two threads of one core (L1TF, MDS, MMIO Stale Data). So the internet-facing VM (Vaultwarden) gets one physical core to itself, and every other VM is pinned to the rest. Why, the CPU layout, the `qm set` commands and the rule for new VMs: [`cpu-affinity.md`](cpu-affinity.md).

---

## pve-overview

[`pve-overview`](pve-overview): one command that prints the whole host + VM resource picture, so there's no clicking through the GUI per VM.

What it shows, top to bottom:

- **Host CPU**: model, sockets, physical cores, threads, SMT on/off.
- **Host memory**: total / used / available, with the ZFS ARC split out (the ARC counts as "used" RAM, which makes the host look fuller than it is).
- **Load, uptime, kernel, PVE version.**
- **One row per VM**: vCPUs, CPU % (5-minute average of the VM's own vCPUs, same source as the GUI graphs), CPU type, core affinity, RAM, RAM actually used, balloon setting.
- **ZFS pools** and their health.
- **CPU vulnerabilities**: each kernel mitigation flagged ok / mitig / partial / VULN.
- **Totals and ratios**: vCPUs allocated vs threads and physical cores, RAM allocated vs host total.
- **RAM budget** (worst case, every running VM uses all of its RAM): what's left for Proxmox itself after the ARC limit, marked OK / LOW / OVER, and which stopped VMs could be started right now without eating the reserve.

Install on the host (as root):

```bash
install -m 0755 pve-overview /usr/local/bin/pve-overview
pve-overview
```

Needs root (`pvesh` does) plus `python3`, `lscpu` and `free`, all on a stock PVE install. Read-only: it changes nothing on the host.

Settings at the top of the script:

| Setting | Default | Meaning |
| --- | --- | --- |
| `HOST_RESERVE_MIB` | `2048` | RAM Proxmox itself should always keep free; below it the budget says LOW |
| `ARCSTATS` | `/proc/spl/kstat/zfs/arcstats` | where the ARC numbers come from (env override) |
| `CONF_DIR` | `/etc/pve/qemu-server` | where the VM configs are read from (env override) |
