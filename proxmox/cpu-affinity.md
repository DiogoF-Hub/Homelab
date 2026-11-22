# CPU affinity: one physical core for the exposed VM

How the Proxmox host keeps the internet-facing VM off the CPU cores the other VMs use, and why SMT stays on anyway.

---

## Why

The host CPU is an Intel Xeon E5-2699 v3 (18 cores, 36 threads) with SMT (Hyper-Threading) on. The kernel reports three issues as "SMT vulnerable":

- **L1TF** (L1 Terminal Fault)
- **MDS** (Microarchitectural Data Sampling)
- **MMIO Stale Data**

All three are side-channel leaks between the two threads of one physical core. Code running inside one VM can read fragments of data that another VM is processing at the same moment on the sibling thread. The leak is read-only and gives random fragments, so it's hard to exploit, but it's real.

Check what the kernel reports on the host:

```bash
grep -H . /sys/devices/system/cpu/vulnerabilities/{l1tf,mds,mmio_stale_data}
```

On this host each line says `Mitigation: ...` and ends with `SMT vulnerable`, for example `mds:Mitigation: Clear CPU buffers; SMT vulnerable`. The mitigation covers one thread switching to another on the same CPU; it can't cover two threads running at the same time on one core, which is the part the affinity below handles.

`pve-overview` lists the same flags in its "CPU VULNERABILITIES" section.

---

## Decision

- **SMT stays on.** Turning it off would halve the threads (36 down to 18) for every VM.
- **The exposed VM gets one physical core to itself.** Vaultwarden is the only VM reachable from the internet, so it's the one an attacker can get code into first. With its own core, no other VM ever runs on its sibling thread: it can't read their data, and they can't read its data.
- **The other VMs share the remaining 17 cores.** They're not exposed, so a side channel between them needs another compromise first.
- **Isolating more VMs was considered and rejected**, for example Wazuh. Reaching them already needs other compromises first, and network isolation (VLANs, firewall rules) protects them far more than a dedicated core would. Each isolated VM would also cost a whole core.

---

## Layout

Linux numbers the threads so that **CPU N and CPU N+18 are the two threads of the same physical core**. Checked with:

```bash
lscpu -e=CPU,CORE
```

| Who | CPUs | Physical cores |
| --- | --- | --- |
| **Vaultwarden** (exposed) | `17,35` | core 17 only (both of its threads) |
| **Every other VM** | `0-16,18-34` | cores 0-16 |

The exposed VM gets the **last** core on purpose: it stays away from CPU 0, where the host does extra work (interrupts, housekeeping).

Its vCPUs all run on those two threads, so giving it more than 2 vCPUs gains nothing.

---

## Important: pin everyone, not just the exposed VM

Pinning only the exposed VM is **not enough**. A VM without an affinity can run on any CPU, including 17 and 35, right next to the exposed VM. **Every** other VM must be pinned away from that core.

---

## Commands

On the Proxmox host, as root:

```bash
# the exposed VM: its own physical core
qm set <vmid> --affinity 17,35

# every other VM, including stopped ones
qm set <vmid> --affinity 0-16,18-34
```

The change applies at the VM's **next full stop and start**. A reboot from inside the VM is not enough. Until then it shows as pending in the GUI.

Check:

```bash
grep affinity /etc/pve/qemu-server/*.conf
```

Every VM file should show up: `17,35` for the exposed VM and `0-16,18-34` for all the others. A VM with snapshots or a pending change can show the line more than once, that's fine. A VM file missing from the list has no affinity yet. The **Affinity** column in `pve-overview` shows the same.

---

## Rule for new VMs

Every new VM gets `0-16,18-34` **before its first start**:

- CLI: `qm set <vmid> --affinity 0-16,18-34`
- GUI: *VM → Hardware → Processors → Advanced → CPU Affinity*

A new VM without it can land on the exposed VM's core.
