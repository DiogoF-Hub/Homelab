# REBUILD, full stack, bare metal to running vault

Step-by-step rebuild runbook for the Vaultwarden stack defined in this
repository. Three audiences in mind:

1. **Replicating the stack from scratch.** You found this repo,
   liked the architecture, and want the same setup running on your
   own infrastructure. This is the primary use case the runbook is
   written for.
2. **Rebuilding after VM loss.** Original operator, lost the VM,
   moving providers, or just validating that the documented procedure
   still works.
3. **Validating the docs.** Reading top-to-bottom to spot drift
   between the runbook and the actual repo / scripts / compose
   files.

Either way: nothing here is theoretical, follow top to bottom, don't
skip.

---

## Who this is for

This runbook describes how to bring up a stack **exactly equal to the
reference setup** described across `README.md`, the compose files, and
the scripts in this repo. If you want a 1:1 replica of that setup,
same VM layout (Vaultwarden VM + `proxy-home` VM + `wazuh-home` VM),
same paths (`/srv/vw-data`, `/root/vault/`, `/home/poduser/vault/`),
same users (`vwadmin`, `poduser`, `fetcher`), same hardening choices
(Cloudflare Tunnel front-end, Squid for HTTP/HTTPS egress, LAN Pi-hole
for DNS with Wazuh visibility, CrowdSec inline at BunkerWeb,
signed-and-encrypted backups with externally-stored pubkey, etc.),
**follow this top to bottom and don't skip steps**.
The whole stack is a system; missing a step typically only manifests
later (a backup that can't be decrypted, a container that can't reach
DNS, a cron that runs the wrong path).

That said, **this is a runbook, not a contract**. Most steps describe
choices the reference setup made that aren't load-bearing, they're
things this stack happens to standardise on so the runbook can be
concrete. Adapt freely if your situation differs:

- **Different storage tier than TrueNAS / Hetzner** → swap them out;
  the only constraint is that `truenas-script.sh` (or your replacement)
  pulls via the `fetcher` user from `/srv/backups/` + `/srv/logs/`,
  and that the second tier is genuinely off-site.
- **Different SMTP provider than Mailjet** → adjust `.env`'s `SMTP_*`
  group and the firewall rule for SMTP egress (rule 6 in the README's
  DMZ table). Make sure the new provider's hostname is in
  `proxy-home/vault_domains_allow_proxy.txt` if SMTP runs through
  Squid, or whitelist it as a direct bypass like Mailjet currently is.
- **Different reverse proxy / WAF** → if you're not using BunkerWeb,
  you're rebuilding a different stack and most of the BunkerWeb-shaped
  phases (3, 12, 17) won't apply directly.
- **No Wazuh manager** → Phase 2's Wazuh-agent step is optional;
  skip it cleanly if you don't have a `wazuh-home` (or equivalent)
  manager to enrol against. Drop the matching checklist item in
  Phase 18 too.
- **Direct exposure instead of Cloudflare Tunnel** → use either
  `docker-compose.public-http01.yml` (HTTP-01 ACME, ports 80 + 443
  open) or `docker-compose.public-dns01.yml` (DNS-01 ACME via
  Cloudflare API, ports 80 + 443 open with port 80 only serving
  the http→https redirect, not ACME). Skip Phase 11 (cloudflared)
  in both cases. The rest of the runbook is identical.
- **CGNAT at home / no routable public IPv4** → can't expose ports
  directly even with the `public-*` flavors. Provision an edge VPS
  doing TCP passthrough back to the home BunkerWeb VM via a
  WireGuard tunnel (with PROXY protocol so the real client IP is
  preserved through the chain); full procedure in
  [`vps/README.md`](vps/README.md). Use Phase 11 alternate (Edge
  VPS + WireGuard) instead of Phase 11 (Cloudflare Tunnel). Pair
  with `docker-compose.public-dns01.yml` for the home side.
- **Different VLAN / IP / hostname conventions** → search-and-replace
  `192.168.173.9` (proxy-home / Squid), `192.168.173.2` (LAN Pi-hole),
  `192.168.50.3` (Vault VM, used in `wazuh-home/dns/manager-rules.xml`),
  `vault.example.com` (the public hostname), `vaultwarden-prod` (the
  Cloudflare tunnel name), and any internal subnet references with your
  own values.

What you should **not** adapt without thinking carefully:

- The split between `poduser` (runs containers) and `root` (runs
  maintenance), the whole hardening story leans on that separation.
- The pinned-binary scheme for `age` + `minisign` (Phase 7), the
  goal is reproducible, version-controlled crypto tooling. Skipping
  pinning makes restores fragile across years.
- The `fetcher` user's read-only access pattern (Phase 9), the
  point is that a stolen TrueNAS-side key can't pivot. Replacing it
  with `root` SSH access destroys that property silently.
- The "minisign pubkey is NOT in the bundle" rule, see README §Backup
  Bundle Structure for the rationale. Bundling the pubkey breaks the
  whole signature trust model.

When in doubt, follow the runbook verbatim first, get a working stack,
then adapt one variable at a time and re-run Phase 15 (restore drill)
after each change to make sure you haven't broken the recovery path.

---

## Distro requirement

This runbook is written for a **Debian-based VM** and uses `apt` package
names + Debian-flavoured systemd defaults throughout.

**Use a server / no-GUI image.** This stack is a headless container host;
nothing in the runbook ever needs a desktop, X11, Wayland, or a display
manager. Installing a GUI would burn ~1 GB of
RAM and a few GB of disk on stuff that never runs, and add a much
larger attack surface (every desktop component is another network
service, another auto-updater, another set of CVEs to track) for zero
gain. Pick the smallest image your distro ships:

- **Recommended: Debian 13 netinst**, with the desktop tasksel
  unchecked. Tick only "SSH server" + "standard system utilities"
  during install. That's the image the reference setup runs;
  everything below has been validated against it.
- **Acceptable: Ubuntu Server LTS** (24.04 or newer), the
  no-GUI ISO. **NOT Ubuntu Desktop.** Package set, paths, and systemd
  behaviour are close enough to Debian that the runbook works as-is;
  the only real differences are `unattended-upgrades` defaults and
  AppArmor's stance on rootless Podman, both noted inline where
  relevant.
- **Anything else** (RHEL/Rocky/Alma, Fedora Server, Arch, NixOS, …),
  do **not** follow this runbook verbatim. Package names differ
  (`dnf` vs `apt`, `podman` rootless prerequisites are packaged
  differently, SELinux contexts on bind mounts behave differently).
  Even if the distro is server-shaped, only attempt this if you can
  translate every `apt install ...` line and every config-file path
  to your distro's equivalents from memory. If you're not sure, use
  Debian.

If you somehow inherit a VM that already has a desktop installed, you
can strip it (`sudo apt purge task-desktop task-gnome-desktop ...
&& sudo apt autoremove`) before continuing, but it's faster and
cleaner to reinstall from a server image.

The companion `proxy-home` VM (Phase 3) is also Debian server; same
logic.

---

## Prerequisites, before you even start

- An **OPNsense** instance (or equivalent L3 firewall/router) acting as
  the gateway for every VLAN this stack uses (VLAN-DMZ for the
  Vaultwarden VM, the VLAN that hosts `proxy-home`, the management
  VLAN, etc.). OPNsense is where all the inter-VLAN rules from
  README §DMZ Firewall Rules actually live.
- **VLANs created in OPNsense** and **trunked (802.1Q tagged) to your
  physical switches** over an uplink/trunk port. The switches in turn
  drop the right tag onto each port that hosts an endpoint, so a
  switch port leading to the Proxmox host is itself a trunk carrying
  the VLAN tags Proxmox needs to expose to its VMs. Plain access ports
  (single-VLAN, untagged) lead to single-VLAN endpoints.
- A **Proxmox host** (or equivalent hypervisor) connected to one of
  those switch trunk ports, with a VLAN-aware Linux bridge configured
  so VM vNICs can be pinned to specific VLAN tags. The Vaultwarden VM
  ends up on VLAN-DMZ via "vNIC → Proxmox bridge → trunked physical
  NIC → switch trunk port → OPNsense", five hops, all of which need
  to agree on the tag.
- Domain with DNS hosted on Cloudflare.
- A Cloudflare account with an **API token** scoped to `Zone:DNS:Edit`
  for your domain (used for the DNS-01 ACME challenge in the `cf-tunnel`
  and `public-dns01` flavours, plus the Cloudflare Tunnel itself in
  `cf-tunnel`). Not required for `public-http01`.
- TrueNAS (or equivalent) for first-tier backup storage. Hetzner Storage
  Box (or equivalent) for second-tier off-site replication.
- A **separate `proxy-home` VM** already running Squid (Phase 3
  describes what must be true on it; if you're rebuilding both, do
  proxy-home first).
- A **DNS resolver reachable from VLAN-DMZ**, the reference setup uses
  the homelab's existing LAN Pi-hole (`192.168.173.2`); any encrypted-
  upstream resolver the firewall lets you reach works. Phase 3 covers
  pointing the Vault VM at it. The Wazuh-side visibility config in
  `wazuh-home/` assumes the LAN Pi-hole specifically.
- A **separate Wazuh manager VM (`wazuh-home`)** if you're matching the
  reference layout, Phase 2 enrols agents to it. If you don't have one
  yet, skip the Wazuh enrollment step and add it later (idea #7 in
  `ideas.md` covers the wider rollout).
- A workstation with `ssh`, the pinned `age` binary (or one downloaded
  from GitHub releases), and, if you're testing restores from Windows,
  the pinned `age.exe` from the backup bundle.
- The **age private identity file** (`identity.txt` from
  README §Age Key Pair Generation, or wherever you keep it). **Without
  this the backups are unrecoverable.** Confirm you have it before
  starting.
- The **minisign public key** (`minisign.pub`) on a trusted external
  medium (printed on paper, USB stick in a safe, password-manager
  attachment). The pubkey is **not** bundled inside backups, that's
  deliberate; see `ideas.md` #1 (DONE stub) and README §Backup Bundle
  Structure. You need an externally-stored copy to verify any bundle.

Secret inventory you must have on hand before Phase 10:

- age private key (above).
- minisign public key (above), and the **minisign private key**
  (`minisign.key`) ready to land on the new VM at
  `/root/vault/minisign.key`. See README §Minisign Key Pair Generation.
- Cloudflare API token (DNS-01 ACME challenge) *or* Cloudflare Tunnel
  token (the long string copied from the tunnel-creation screen in the
  Zero Trust dashboard, Phase 11 walks through getting it).
- CrowdSec enroll key (new one from app.crowdsec.net, or the existing
  one if you're re-enrolling the same instance).
- CrowdSec bouncer key, generate with `openssl rand -base64 48`. It's
  local-only, used by both CrowdSec LAPI (`BOUNCER_KEY_PROXY` env var,
  pre-creates a bouncer with this key on first start) and BunkerWeb's
  bouncer plugin (`CROWDSEC_API_KEY` env var). Same value in both places.
- Vaultwarden `ADMIN_TOKEN`, an Argon2id hash of your admin password.
  Generate inside the running vaultwarden container with
  `podman exec -it vaultwarden /vaultwarden hash` (prompts twice for the
  password, prints the hash). Wrap the entire `$argon2id$...` value in
  single quotes in `.env` so the shell doesn't try to interpolate the
  `$argon2id`, `$v`, `$m` segments as variables.
- Mailjet (or equivalent) SMTP credentials.
- Wazuh agent registration secret (only if matching the reference
  setup, obtained from your `wazuh-home` manager).
- The `.env.template` from this repo (you have this, it's checked in).

---

## Phase 1, Proxmox VM

1. Create VM: Debian 13 netinst ISO, 2 vCPU, 2 GB RAM, 20 GB disk
   (adjust to your backup-retention math). Machine type `q35`, BIOS
   OVMF/UEFI if you prefer secure boot, not required.
2. **Single vNIC pinned to VLAN-DMZ.** No second NIC. The whole point
   is that this VM has exactly one routable path out, and it goes
   through the `proxy-home` VM. Concretely, in the Proxmox VM's
   hardware tab:
   - Bridge: a VLAN-aware Linux bridge whose physical NIC is the
     trunked uplink to your switch (and therefore to OPNsense).
     The reference setup uses one bridge with VLAN awareness enabled,
     not per-VLAN bridges.
   - VLAN Tag: the numeric ID OPNsense assigned to VLAN-DMZ. Proxmox
     stamps every frame from this vNIC with that tag; the switch sees
     the tag, OPNsense sees the tag, the Vaultwarden VM never has to
     think about VLAN tagging itself (the OS sees a plain Ethernet
     interface with a regular IP).
   - Firewall: leave Proxmox's per-vNIC firewall **off**. OPNsense
     enforces the rules; Proxmox's per-vNIC firewall would just add
     a second policy surface drifting against OPNsense's.
3. Boot the ISO, do a minimal install: SSH server, standard system
   utilities, nothing else. No desktop. No print server. No web server.
4. During install, set a strong root password (you'll disable root
   login later anyway) and create the **non-root admin user**. The
   reference setup names this account `vwadmin` (uid 1000, default
   `/bin/bash` shell, password set during install). The runbook below
   uses `vwadmin` consistently; pick a different name if you prefer,
   but then search-and-replace it everywhere it appears (sshd
   `AllowUsers`, sudo references, Phase 2 hardening commands).
5. **Pin the VM's IP address.** The Vaultwarden VM needs a stable IP
   so OPNsense's per-source firewall rules (and `fetcher`'s SSH key
   auth, and the TrueNAS-side scp target) keep working across reboots.
   Either approach is fine, pick one and stick with it:
   - **Static DHCP reservation in OPNsense** (recommended for fleet
     consistency): note the VM's vNIC MAC address, then in OPNsense
     under *Services → DHCPv4 → \[VLAN-DMZ\] → Static* add a
     reservation pinning that MAC to the desired IP. On reboot the VM
     gets the same IP automatically. Keeps the IP source-of-truth in
     OPNsense alongside the firewall rules.
   - **Static IP configured on the VM itself** (Debian's `/etc/network/interfaces`
     or `systemd-networkd` / `netplan`, depending on what the installer
     chose). Disable DHCP for that interface entirely. Keeps the IP
     source-of-truth on the VM. Choose this if you don't want OPNsense
     to be a single point of failure for the VM's networking even at
     boot.

   Either way the result is the same: the VM has a deterministic IP on
   VLAN-DMZ. The runbook below uses `<vm-ip>` as a placeholder; replace
   with whatever you pinned.
6. Verify the VLAN actually landed before continuing: from another
   host on VLAN-DMZ, `ping <vm-ip>` should succeed; from a host on
   a *different* VLAN it should fail (OPNsense's catch-all VLAN block,
   rule 3 in the firewall table). If both succeed, the trunk/tag chain
   is misconfigured somewhere, fix it before doing any hardening.

## Phase 2, Debian base hardening

From a fresh SSH session as `vwadmin`:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y sudo curl ca-certificates unattended-upgrades \
    apt-listchanges fail2ban rsyslog python3-yaml jq
sudo dpkg-reconfigure -plow unattended-upgrades
```

`python3-yaml` is needed by `docker-update.sh`, which parses
`podman-compose config` output via Python's yaml module to resolve
the image name per service. Earlier versions used awk and silently
returned the wrong image when one service's name appeared inside
another service's `depends_on` block (awk has no concept of YAML
nesting; the yaml parser does). python3 itself is in Debian's base
install, but PyYAML isn't.

`rsyslog` is listed alongside `fail2ban` deliberately: Debian 13
ships with journald-only logging by default, and the fail2ban
config below points at `/var/log/auth.log`. Without rsyslog, that
file doesn't exist and the sshd jail fails to start. rsyslog's
package config splits authpriv events into auth.log automatically.

`jq` is used by `main.sh`'s `emit_run_summary` to roll the per-phase JSON
status lines into the nightly `run` summary the Wazuh maintenance pipeline
ships to #maintenance Discord. The per-phase emit is printf-built and needs
no jq; only the rollup does (and it degrades to an overall-status-only
summary without it). See the Wazuh agent section below.

Configure fail2ban with an `sshd` jail at
`/etc/fail2ban/jail.local`:

```ini
[sshd]
enabled = true
backend = auto
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 10m
bantime = 1h
```

Three failed SSH auth attempts within 10 minutes earn a 1-hour ban.
`backend = auto` + explicit `logpath` forces file-poll mode against
auth.log (which is why rsyslog matters; the alternative is
`backend = systemd` reading journald directly, not the path
deployed here). Enable + start:

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

The status command should print the jail's current state (banned
IPs + total bans) and confirms the sshd jail is loaded.

The reference setup edits the **main** `/etc/ssh/sshd_config` file
directly (the `Include /etc/ssh/sshd_config.d/*.conf` line at the top
is left commented out, so drop-in files in that directory would be
**ignored**). Replace the relevant directives in `/etc/ssh/sshd_config`
with the following (or paste this as the full file, every line below
either matches the OpenSSH default or is an intentional hardening
choice):

```
# Non-default SSH port (any port that is NOT 22). The exact value is
# noise reduction against drive-by scanners, not a security control;
# whichever port you pick has to match truenas-script.sh's VM_PORT
# and the `-p <port>` / `-P <port>` flags in Phase 9's fetcher smoke
# test, the UFW allow rule, and any OPNsense pass rules upstream.
Port <ssh_port>

# Only these two accounts can SSH in. vwadmin = management; fetcher =
# TrueNAS-side scp puller (Phase 9). poduser is intentionally absent,
# it's a containers-runtime account, never reached over SSH.
AllowUsers vwadmin fetcher

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Authentication
LoginGraceTime 30
PermitRootLogin no
MaxAuthTries 2
MaxSessions 2

PubkeyAuthentication yes
ChallengeResponseAuthentication no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no

AuthorizedKeysFile     .ssh/authorized_keys

# Disable PAM, fine here because we never want password / Kerberos /
# challenge-response paths. If you ever need to re-enable it (e.g. for
# 2FA via PAM), revisit MaxAuthTries / KbdInteractiveAuthentication too.
UsePAM no

# Forwarding off by default, this VM is a leaf, not a jump box.
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no

# Quieter sessions; less info disclosure on connect.
PrintMotd no
PrintLastLog no
TCPKeepAlive no
Compression no

# Idle-session reaper (5 min × 2 = ~10 min before kick).
ClientAliveInterval 300
ClientAliveCountMax 2

# Don't reverse-DNS clients, faster connects, no leak of who's
# resolving what to upstream resolvers.
UseDNS no

# Restrict which env vars clients can pass through. Default is "LANG LC_*"
#, the reference setup adds COLORTERM and NO_COLOR for sane terminal rendering.
AcceptEnv LANG LC_* COLORTERM NO_COLOR

Subsystem       sftp    /usr/lib/openssh/sftp-server
```

> **About the commented-out `Include`:** the default Debian/Ubuntu
> `sshd_config` ships with `#Include /etc/ssh/sshd_config.d/*.conf` at
> the top. The reference setup keeps it **commented** so the canonical
> config lives in one file. If you prefer drop-in files, uncomment the
> `Include` and split the directives into a 99-hardening.conf, but
> then your sshd_config and the snippet above will visually diverge,
> and a future rebuild reading both files will get confused. Pick one
> approach.

> **`AllowUsers` rationale:** with `PasswordAuthentication no` AND
> `AllowUsers` together, only `vwadmin` and `fetcher` can ever SSH in,
> and only with a matching key in their `~/.ssh/authorized_keys`. If
> you don't intend to set up the off-site backup pull path, drop
> `fetcher` from the line and skip Phase 9 entirely; you can always
> add it back later (and remember to `systemctl restart ssh` after the
> edit).

Before restarting sshd: copy your workstation pubkey to
`/home/vwadmin/.ssh/authorized_keys` **first**, otherwise the next
session will lock you out:

```bash
sudo mkdir -p /home/vwadmin/.ssh
sudo nano /home/vwadmin/.ssh/authorized_keys   # paste your workstation pubkey
sudo chown -R vwadmin:vwadmin /home/vwadmin/.ssh
sudo chmod 700 /home/vwadmin/.ssh
sudo chmod 600 /home/vwadmin/.ssh/authorized_keys

# Now apply the new config:
sudo systemctl restart ssh
```

Verify you can still log in from a **second terminal** (using
`ssh -p <ssh_port> vwadmin@<vm-ip>`) **before** closing the first one. If
you can't, first terminal's still open, fix the config, restart sshd,
try the second terminal again.

Basic `nftables` / `iptables` / `ufw` (pick one, the reference setup
relies on upstream OPNsense rules, so the on-host firewall here is just
defence-in-depth):

- Allow `ssh` in from your management IP range only.
- Default-deny everything else.

No further on-host firewalling is needed because egress control is
enforced upstream: HTTP/HTTPS via Squid on the `proxy-home` VM, DNS via
the LAN Pi-hole.

### QUIC UDP buffer tuning (host kernel)

`cloudflared` uses QUIC and warns/drops packets if the kernel's UDP
receive buffer is too small. Apply this once on the VM:

```bash
sudo sysctl -w net.core.rmem_max=7500000
sudo sysctl -w net.core.wmem_max=7500000

# Persist across reboots
echo "net.core.rmem_max=7500000" | sudo tee -a /etc/sysctl.d/99-udp-buffer.conf
echo "net.core.wmem_max=7500000" | sudo tee -a /etc/sysctl.d/99-udp-buffer.conf
```

Reference: [quic-go UDP Buffer Sizes](https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes).
This is a host-level kernel setting, applies to every container.

### Wazuh agent (if matching the reference setup)

The reference setup runs the Wazuh agent on every VM (Vaultwarden VM +
`proxy-home` VM + LAN Pi-hole VM + `wazuh-home` itself), enrolled with a
dedicated `wazuh-home` manager. What each ships:

- **Vaultwarden VM**, a `modsec-tail.py` sidecar (runs as a dedicated
  unprivileged `modsectail` user) flattens BunkerWeb's `modsec_audit.log`
  into `/var/log/modsec-events/events.log`; the agent tails that; manager
  rules 100300-100303 tier WAF events by CRS anomaly score.
- **`proxy-home` VM**, the agent installer auto-discovers Squid's
  `/var/log/squid/access.log` (no manual config; built-in squid decoder).
- **LAN Pi-hole VM**, a `pihole-ftl-tail.py` sidecar polls Pi-hole's FTL
  SQLite DB and emits per-query JSON to `/var/log/vault-dns/events.log`;
  manager rules 100250-100253.
- **The four home VMs running the sshd jail** (vault, manager,
  proxy-home, pihole) each tail `/var/log/fail2ban.log`; manager
  `fail2ban-file` decoder + rule 100401 fire on a ban. The edge VPS runs
  fail2ban too but has no Wazuh agent, so its bans aren't shipped.
- **Vaultwarden VM (maintenance)**, `main.sh` writes a JSON status log
  (`/srv/logs/status/*.jsonl`) that the agent tails (single-file localfile);
  manager rules 100500-100502 turn the nightly run summary into a
  #maintenance Discord report (green OK, @ on degraded/fail). Wire this
  after the first `main.sh` run (Phase 14), since the log is born then.

All five sources also fan out to per-channel Discord via one
`custom-discord` integrator (real webhook URLs live in a gitignored
`discord-webhooks.json` side-file on the manager, not in the script).
Decoders, rules, sidecars, localfiles, and the integrator all live in
[`wazuh-home/`](./wazuh-home/); follow its README for the full apply
procedure (the `modsec-tail.service` and `pihole-ftl-tail.service` headers
carry the per-host install commands, and README §Log Rotation has the
`modsec-events` + `vault-dns` logrotate text). Idea #7 in `ideas.md` covers
what's still pending: shipping `vw-logs/` / `bw-logs/`, the no-run-in-25h
deadman-equivalent rule, and FIM.

If you don't have a Wazuh manager and don't plan to add one, skip this
sub-section entirely.

Install the agent + apt repo (from Wazuh's official install guide for
the version you're standardising on). Confirm `packages.wazuh.com` is
in `proxy-home/vault_domains_allow_proxy.txt` so the apt fetch flows
through Squid (Phase 4 wires Squid up; the agent install can wait until
after Phase 4 if it's blocking on Squid availability). The Vaultwarden
VM's `modsec-tail` sidecar can only go in after the BunkerWeb stack is
up (Phase 10+), since it tails `/srv/bw-logs/`.

## Phase 3, prerequisites on other hosts

The Vaultwarden VM does no outbound itself; it relies on two upstream
chokepoints that need to be in place **before** Phase 4 wires the VM up
to use them.

### `proxy-home` VM (HTTP/HTTPS egress)

Hosts **Squid** on port `3128`, allowlist-enforced by
`proxy-home/squid.conf` (the canonical allowlist is
`proxy-home/vault_domains_allow_proxy.txt`, deployed to
`/etc/squid/allowed_domains.txt` on the proxy-home VM). The Vaultwarden
VM uses this as its `http_proxy` / `https_proxy` for all egress.

You almost certainly already have this VM running. Things to verify:

- Squid running, allowlist applied, port 3128 reachable from VLAN-DMZ.
- `ufw` allows port 3128/tcp from the VLAN-DMZ subnet only.

### LAN Pi-hole (DNS resolution + Wazuh visibility)

The Vault VM's DNS goes to the homelab's existing **LAN Pi-hole**
(`192.168.173.2`) instead of running a dedicated DoH gateway just for
this VM. Pi-hole forwards upstream over DoH to Cloudflare Family via
its own `adguard/dnsproxy` sidecar, so the encryption story is
preserved; visibility comes from Pi-hole's `pihole.log` being shipped
to Wazuh through a custom decoder + rule chain (see
[`wazuh-home/README.md`](./wazuh-home/README.md)).

Routing the Vault VM's DNS through this layer serves two purposes, both
of which matter:

1. **Encryption.** Plaintext UDP/53 to a public resolver is sniffable on
   every hop between the VM and that resolver. Pi-hole's DoH upstream
   means that leg is encrypted; the LAN-internal DMZ → LAN hop stays
   on trusted infrastructure.
2. **Logging visibility.** Every name the Vault VM ever resolves
   (`vault.example.com`, Let's Encrypt endpoints, Cloudflare Tunnel,
   CrowdSec hub, apt mirrors, container registries, Wazuh feeds, the
   `icons.bitwarden.net` redirect, …) is captured in `pihole.log` and
   surfaced as a level-3 Wazuh alert filtered to the Vault VM's source
   IP. That's the difference between "I trust the VM is only resolving
   what it should" and "I can prove it." Without this layer there is
   **no** record of what the VM asked for at the DNS level, a
   meaningful blind spot if anything ever goes wrong on the host.

Things to verify on the LAN Pi-hole VM before continuing:

- Pi-hole running, dnsproxy sidecar (or your equivalent) doing the DoH
  upstream resolution, port 53 reachable from VLAN-DMZ.
- FTL SQLite DB reachable on the host: Pi-hole compose has
  `/var/log/pihole:/var/log/pihole` AND the `/etc/pihole` bind mount in
  place (the latter is where `pihole-FTL.db` lives, default path
  `/home/pi/pihole/data/etc-pihole/pihole-FTL.db` for the reference
  setup). Confirm with `sudo sqlite3 -readonly <path> "SELECT count(*) FROM queries"`.
- Pi-hole group `vaultwarden-vm` exists with the Vault VM as client and
  **no adlists ticked** for that group (Squid is the actual content
  gate; DNS-layer blocking would just add a hard-to-diagnose failure
  mode).
- Sidecar daemon installed on the Pi-hole VM:
  `wazuh-home/sidecar/pihole/pihole-ftl-tail.py` at `/usr/local/sbin/`,
  `wazuh-home/sidecar/pihole/pihole-ftl-tail.service` at `/etc/systemd/system/`,
  enabled and running (`sudo systemctl status pihole-ftl-tail`).
  The daemon writes structured JSON events to
  `/var/log/vault-dns/events.log`.
- Wazuh agent on the Pi-hole VM with the localfile blocks from
  `wazuh-home/dns/pihole-agent.localfile.xml` applied (tails the sidecar's
  output log); manager-side rules from
  `wazuh-home/dns/manager-rules.xml` applied to wazuh-home; `logall_json`
  from `wazuh-home/manager/manager-global.snippet.xml` flipped on; optionally
  filebeat's wazuh archives module also enabled
  (`/etc/filebeat/filebeat.yml`, `archives.enabled: true`) so the
  `wazuh-archives-4.x-*` index appears in the dashboard for catch-all
  rule 100250 events. Smoke test: trigger an `nslookup` from the
  Vault VM and watch alerts.json for rule 100251 (resolved), 100252
  (Pi-hole policy block), or 100253 (upstream no-answer). Full apply
  procedure in [`wazuh-home/README.md`](./wazuh-home/README.md).

### Firewall (DMZ → both chokepoints)

OPNsense (or equivalent), see README §DMZ Firewall Rules. The two
relevant allows: rule 1 (`VLAN-DMZ → 192.168.173.9:3128`, Squid on the
`proxy-home` VM) and rule 2 (`VLAN-DMZ → 192.168.173.2:53`, the LAN
Pi-hole). Rule 3 is the catch-all VLAN block, sitting **after** both
allows.
- Rule 6 (SMTP/587 direct to Mailjet) is in place so the Vaultwarden VM
  can reach SMTP without going through Squid.

Smoke test from the Vaultwarden VM (will work once Phase 4 is done):

```bash
http_proxy=http://192.168.173.9:3128 curl -I https://deb.debian.org   # expect 200
nslookup deb.debian.org 192.168.173.2                                  # expect real answers
```

## Phase 4, Wire the Vaultwarden VM through its chokepoints

The VM has **two** outbound paths to wire: HTTP/HTTPS via Squid on the
`proxy-home` VM (`192.168.173.9:3128`), and DNS via the LAN Pi-hole
(`192.168.173.2:53`).

### apt → Squid

```bash
sudo nano /etc/apt/apt.conf.d/95proxy
```

Paste:

```
Acquire::http::Proxy "http://192.168.173.9:3128";
Acquire::https::Proxy "http://192.168.173.9:3128";
```

### System-wide HTTP/HTTPS proxy (four files)

Per README §System-Wide Proxy Configuration, a single `/etc/environment`
entry is **not enough**. systemd doesn't read it, sudo strips it, and
interactive shells don't always pick it up. Four files are needed.

**1.** `/etc/environment`, global env for all programs launched normally:

```
http_proxy="http://192.168.173.9:3128"
https_proxy="http://192.168.173.9:3128"
HTTP_PROXY="http://192.168.173.9:3128"
HTTPS_PROXY="http://192.168.173.9:3128"
NO_PROXY="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
no_proxy="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
```

**2.** `/etc/systemd/system.conf.d/proxy.conf`, for systemd services
(systemd does NOT read `/etc/environment`):

```ini
[Manager]
DefaultEnvironment="HTTP_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="http_proxy=http://192.168.173.9:3128"
DefaultEnvironment="HTTPS_PROXY=http://192.168.173.9:3128"
DefaultEnvironment="https_proxy=http://192.168.173.9:3128"
DefaultEnvironment="NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
DefaultEnvironment="no_proxy=localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
```

**3.** `/etc/profile.d/proxy.sh`, for interactive SSH shells:

```bash
export http_proxy="http://192.168.173.9:3128"
export https_proxy="http://192.168.173.9:3128"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export no_proxy="localhost,127.0.0.1,0.0.0.0,::1,bunkerweb,crowdsec,vaultwarden,cloudflared"
export NO_PROXY="$no_proxy"
```

**4.** sudoers, preserve proxy vars through `sudo` (`main.sh`'s
`sudo -u poduser` calls fail otherwise):

```bash
sudo visudo
```

Add:

```
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"
```

### DNS → LAN Pi-hole

The Vaultwarden VM's resolver must be **`192.168.173.2` only** (the LAN
Pi-hole), with **no fallback** to a public resolver. Both parts of the
design, encryption AND log visibility (see Phase 3 for the rationale),
depend on every query going through Pi-hole. Leaving `1.1.1.1` or
`8.8.8.8` in the resolver list as a fallback quietly defeats both:
queries to those fallbacks aren't routed through Pi-hole's DoH upstream,
and they don't show up in `pihole.log` (and therefore don't surface as
Wazuh alerts). The moment Pi-hole briefly hiccups, the VM silently
bypasses the entire layer with no record of what it asked for.

Two ways to land that, pick one (mirroring the Phase 1 IP-pinning
choice):

**Option A, DHCP option 6 from OPNsense.** In *Services → DHCPv4 →
\[VLAN-DMZ\]*, set the DNS server to `192.168.173.2` (and **only**
`192.168.173.2`). Renew the lease on the VM (`sudo dhclient -r && sudo
dhclient` or just reboot). `/etc/resolv.conf` populates automatically.
Keeps the resolver source-of-truth in OPNsense alongside the IP
reservation, recommended if you also chose DHCP-reservation in
Phase 1.

**Option B, static on the VM.** Edit `/etc/resolv.conf` directly (or
the layer that auto-populates it, `systemd-resolved`, `netplan`,
`/etc/network/interfaces`, depending on your install):

```bash
sudo nano /etc/resolv.conf
```

Replace contents with:

```
nameserver 192.168.173.2
```

Don't fight the auto-population: if `systemd-resolved` is managing
`/etc/resolv.conf`, set the resolver under
`/etc/systemd/resolved.conf.d/dns.conf` instead. If netplan is
managing it, set it in `/etc/netplan/*.yaml`. Choose this option if
you also chose static-on-VM in Phase 1.

### Verify

```bash
# Re-login or `source /etc/environment` first, then:
sudo apt update                                        # expect: 200s, no 403s
nslookup deb.debian.org                                # expect: real answers via 192.168.173.2
http_proxy=http://192.168.173.9:3128 curl -I https://deb.debian.org   # expect: 200
```

If you applied the `wazuh-home/` config earlier, also confirm the alert
chain end-to-end. On wazuh-home:

```bash
sudo tail -f /var/ossec/logs/alerts/alerts.json \
  | jq -r 'select(.rule.id=="100251" or .rule.id=="100252" or .rule.id=="100253") | "\(.timestamp) [\(.rule.id)] \(.data.qtype) \(.data.query) \(.data.status)"'
```

The `nslookup` above should produce a rule-100251 (resolved) alert
within ~10 seconds (the sidecar's polling interval). Try also
`nslookup ads.google.com 192.168.173.2` to confirm rule 100252
(Pi-hole policy block) fires for an exact-deny test domain in
Pi-hole, and `nslookup rivestream.xyz 192.168.173.2` to confirm
rule 100253 (upstream no-answer) for a Cloudflare-Family-blocked
domain.

If `apt update` 403s, the Squid allowlist is missing a Debian mirror,
cross-check `proxy-home/vault_domains_allow_proxy.txt` against the
mirror in `/etc/apt/sources.list`.

## Phase 5, Podman rootless as `poduser`

```bash
sudo adduser --disabled-password --gecos "" poduser
sudo apt install -y podman podman-compose uidmap slirp4netns fuse-overlayfs
sudo loginctl enable-linger poduser
sudo su - poduser -c 'podman info'   # should run without root, no errors; exit back to your previous shell after
```

Add the `pcup` / `pcdown` helpers system-wide so any user managing the
stack can call them without leaking secrets in the terminal output (the
compose files print every env var on `up`):

```bash
sudo nano /etc/profile.d/podman_compose_aliases.sh
```

Paste (per README §Global Podman Compose Aliases):

```bash
pcup() {
    podman-compose up -d >/dev/null 2>&1
}

pcdown() {
    podman-compose down >/dev/null 2>&1
}
```

## Phase 6, Directory tree on `/srv`

Still as `sudo`:

```bash
# Application data + logs
sudo mkdir -p /srv/vw-data /srv/vw-logs /srv/bw-logs
sudo chown -R poduser:poduser /srv/vw-data /srv/vw-logs /srv/bw-logs
sudo chmod 750 /srv/vw-data /srv/vw-logs /srv/bw-logs

# Backups + maintenance script logs
sudo mkdir -p /srv/backups
sudo mkdir -p /srv/logs/{main,backup,docker,system,status}

# Pinned-tools dirs (populated by Phase 8)
sudo mkdir -p /srv/tools/age /srv/tools/minisign
```

These paths are load-bearing, `lib.sh`, the compose files, the
maintenance scripts, and the TrueNAS-side `truenas-script.sh` all
expect them. Don't move them.

## Phase 7, Deploy the maintenance toolkit to `/root/vault/`

All root-owned scripts live in **one directory**, `/root/vault/`. This
is `${ROOT_VAULT_DIR}` per `lib.sh` (auto-derived from where `lib.sh`
itself sits). The repo splits scripts across `root_scripts/` and
`setups_scripts/` for organisation, but on the VM **both flatten into
`/root/vault/`**.

From your workstation, copy the files to the VM (or copy them up via
the repo checkout in Phase 10 once it's there):

```bash
# Files to deploy into /root/vault/:
#   scripts/root_scripts/{main,lib,backup,docker-update,system-update,reboot}.sh
#   scripts/setups_scripts/{setup-age,setup-minisign}.sh
#
# Permissions: 700 root:root on the directory and all .sh files.
# lib.sh is sourced (not executed), the +x bit is harmless but optional.
```

```bash
sudo chown -R root:root /root/vault
sudo chmod 700 /root/vault
sudo chmod 700 /root/vault/*.sh
```

Then run the binary-pinning scripts. Each pulls from GitHub (via Squid),
extracts both Linux + Windows binaries into `/srv/tools/<tool>/<version>/`,
and records SHA-256s. They use `find` to locate binaries inside extracted
archives, so they're resilient to upstream layout changes.

```bash
sudo /root/vault/setup-age.sh
sudo /root/vault/setup-minisign.sh
```

After both run, **confirm the version constants in `lib.sh` match what
just got pinned**:

- `AGE_VERSION` (currently `v1.3.1`)
- `MINISIGN_VERSION` (currently `0.12`)

If `setup-age.sh` pulled a newer version (e.g. `v1.4.0`) and you want
to use it, edit `lib.sh`'s `AGE_VERSION`. The script does **not**
auto-bump the constant, that's deliberate, so an upgrade can't happen
silently.

> **Path note:** neither `age` nor `minisign` is on `PATH`, `lib.sh`
> builds the absolute paths from the version constants
> (`${AGE_BINARY}`, `${MINISIGN_BINARY}`). All scripts in
> `root_scripts/` already use those constants. Humans running either
> tool by hand need the full path, e.g. `/srv/tools/age/v1.3.1/age`.

## Phase 8, Backup-crypto material in `/root/vault/`

Four files must exist in `/root/vault/` with the right ownership and
mode before the first `main.sh` run. **How** you get them onto the VM
(scp, copy-paste into `nano`, USB pass-through, etc.) is out of scope
for this runbook, only the resulting state matters.

### Required end-state

```
$ sudo ls -l /root/vault/{age-recipient.txt,minisign.key,minisign.pub,DECRYPT.txt}
-rw-r--r-- 1 root root  ... DECRYPT.txt
-rw------- 1 root root  ... age-recipient.txt
-rw------- 1 root root  ... minisign.key
-rw-r--r-- 1 root root  ... minisign.pub
```

Permissions / ownership rule of thumb after the files are in place:

```bash
sudo chown root:root /root/vault/{age-recipient.txt,minisign.key,minisign.pub,DECRYPT.txt}
sudo chmod 600       /root/vault/{age-recipient.txt,minisign.key}
sudo chmod 644       /root/vault/{minisign.pub,DECRYPT.txt}
```

`lib.sh:verify_minisign_prereqs()` warns if `minisign.key` is anything
other than `600`, fix it now rather than at the next `main.sh` run.

### What goes in each file

- **`age-recipient.txt`**, the age **public** key (one line starting
  `age1...`). Generated on a clean machine per README §Age Key Pair
  Generation; copy only the public line into this file. The matching
  **private** key (`identity.txt`) **never** lands on this VM, keep
  it on a USB stick / printed paper / encrypted offline backup.
  Plural of "not on this VM."
- **`minisign.key`**, the minisign **private** key. Has to live on
  the VM so `backup.sh` can sign each bundle unattended. Generate with
  **no passphrase**, `lib.sh`'s `MINISIGN_KEY_PASSPHRASE_FILE` is
  intentionally empty (see the `lib.sh` comments around line 132 for
  why). Procedure: README §Minisign Key Pair Generation.
- **`minisign.pub`**, the matching minisign **public** key. Also
  distribute this to every verifier (workstation, TrueNAS,
  restore-test machine). The pubkey embedded in any bundle's manifest
  is a lookup hint, **not** a trust anchor, see README §Backup Bundle
  Structure.
- **`DECRYPT.txt`**, the canonical copy of the repo-root `DECRYPT.txt`.
  `backup.sh` reads it from `${DECRYPT_TXT}` (which `lib.sh` builds as
  `/root/vault/DECRYPT.txt`) and bundles a copy into every backup,
  editing this file directly affects what end-users see at restore
  time, so version-control your edits via the repo copy and re-deploy
  rather than editing the on-VM file in place.

## Phase 9, `fetcher` user (TrueNAS pull source)

The TrueNAS-side `truenas-script.sh` pulls daily bundles + phase logs
via `scp` from the Vaultwarden VM. It uses a purpose-built unprivileged
account called `fetcher` rather than root, so a stolen TrueNAS-side key
can't pivot anywhere on the VM. See README §Off-site replication for
the full design rationale.

Reference end-state (a `/etc/passwd` line straight from a working
build):

```
fetcher:x:1002:1002:,,,:/home/fetcher:/bin/bash
```

Default `/bin/bash` shell, password set during creation, **not in any
extra groups**. The lockdown comes from the SSH daemon
(`PasswordAuthentication no` + `AllowUsers vwadmin fetcher` from
Phase 2) and from the filesystem (no sudo, read-only access scope),
**not** from a `nologin` shell, forcing `nologin` would break scp
under some sshd configurations and gain nothing meaningful.

Create the account:

```bash
# Standard interactive adduser, accept the default shell (/bin/bash)
# and set a password when prompted (the password is unused for SSH
# because PasswordAuthentication=no is set in sshd, but creating the
# account without one is fragile across distros).
sudo adduser fetcher

# Confirm not in sudo or any other privileged group:
groups fetcher   # expect: just "fetcher"
```

### Authorize the TrueNAS-side public key

**How** the public key gets into `/home/fetcher/.ssh/authorized_keys`
(scp from your workstation, `nano` paste, `ssh-copy-id` from TrueNAS,
etc.) is out of scope for this runbook, only the resulting state
matters.

End-state:

```
$ sudo ls -ld /home/fetcher/.ssh /home/fetcher/.ssh/authorized_keys
drwx------ 2 fetcher fetcher  ... /home/fetcher/.ssh
-rw------- 1 fetcher fetcher  ... /home/fetcher/.ssh/authorized_keys
```

The `authorized_keys` file contains a **single** line: the public key
matching `/root/.ssh/fetcher_automation_rsa` on TrueNAS (the path
`truenas-script.sh` uses for its `SSH_KEY` constant).

Permissions / ownership rule of thumb after the file is in place:

```bash
sudo chown -R fetcher:fetcher /home/fetcher/.ssh
sudo chmod 700               /home/fetcher/.ssh
sudo chmod 600               /home/fetcher/.ssh/authorized_keys
```

sshd refuses to use an `authorized_keys` file that is group- or
world-writable, and refuses an `~/.ssh` that is group- or
world-readable. Get the modes wrong and the smoke test below fails
with a generic "Permission denied (publickey)", there is no friendlier
error for this.

Verify Phase 2's `AllowUsers` line includes `fetcher` (it should, per
the snippet there). If you forgot, add `fetcher` to the list now and
`sudo systemctl restart ssh`, without this, the SSH daemon rejects
fetcher's connection regardless of key validity.

Grant `fetcher` read-only access to **only** the two paths it pulls
from. Every implementation detail (group ownership, ACLs, dir perms) is
fine as long as the resulting access pattern matches:

- ✅ `fetcher` can read every file under `/srv/backups/` and
      `/srv/logs/{main,backup,docker,system}/`
- ❌ `fetcher` cannot write anywhere
- ❌ `fetcher` cannot read `/srv/vw-data/`, `/srv/vw-logs/`,
      `/srv/bw-logs/`, the compose files, or anything under `/root/`

Smoke test from TrueNAS once the keypair is in place:

```bash
ssh -i /root/.ssh/fetcher_automation_rsa -p <ssh_port> fetcher@<vm-ip> exit   # expect: 0
scp -i /root/.ssh/fetcher_automation_rsa -P <ssh_port> \
    fetcher@<vm-ip>:/srv/backups/                                          \
    /tmp/test-pull/                                                        # expect: lists files OK
```

## Phase 10, Repo checkout (poduser side) + `.env`

```bash
sudo su - poduser
cd ~
git clone <repo-url> vault                   # use this repo's clone URL (or your own fork). NOT 'vaultwarden', the dir name must match COMPOSE_DIR's basename in lib.sh
cd vault/bunkerweb
```

> **Path note:** `lib.sh` derives `COMPOSE_DIR` from the basename of
> `ROOT_VAULT_DIR`, `/root/vault → /home/poduser/vault`. If you check
> the repo out as `~/vaultwarden` instead of `~/vault`, `stop_containers()`
> in `lib.sh` will `cd` into the wrong directory and silently fail to
> stop running containers, corrupting the next backup. Match the name.

Copy `.env.template` → `.env` and fill in **every** value. The file is
grouped by purpose (infra / ACME / tunnel / BunkerWeb UI / CrowdSec /
Vaultwarden / SMTP). Do not commit the filled `.env`.

**Web UI TLS cert.** All three flavours set `UI_SSL_ENABLED=yes` for the
BunkerWeb admin UI (port 7000) and bind-mount its cert from
`/srv/bw-ui-tls`, so that dir must hold `cert.pem` + `key.pem` before the
first boot (Phase 12) or the UI won't start. Generate an internal-CA-signed
leaf off-box (SANs for the VM hostname + its LAN IP, e.g. `vaultwarden-home`
+ `192.168.50.3`), then place it:

```bash
sudo mkdir -p /srv/bw-ui-tls
# copy cert.pem + key.pem in (scp / paste), then:
sudo chown poduser:poduser /srv/bw-ui-tls/cert.pem /srv/bw-ui-tls/key.pem
sudo chmod 0644 /srv/bw-ui-tls/cert.pem
sudo chmod 0600 /srv/bw-ui-tls/key.pem
```

The UI loads its cert as root at container startup (poduser maps to
container-root in the rootless userns), so `poduser:poduser 0600` on the key
is readable, no need to chown to a subuid. The admin account is seeded from
`.env`'s `UI_ADMIN_*` on first boot, so there's no setup wizard to complete.

Pick your flavour. **What's actually running in this deployment**:
`docker-compose.public-dns01.yml` paired with the edge VPS in
[`vps/`](vps/) (Phase 11 alternate). The other two are kept in the
repo as fully-working references; pick whichever fits your situation:

- **Direct exposure with DNS-01 ACME, paired with edge VPS** (this is
  what's currently running; ports 80 + 443 on the VM; port 80 used
  only for the http→https redirect convenience, NOT for ACME; cert
  validation goes via your Cloudflare DNS API token; the VPS does
  TCP passthrough with PROXY protocol so the home-side IP-based
  defenses see real client IPs) → `docker-compose.public-dns01.yml`.
  Most of this runbook below assumes this combo. To close port 80
  entirely (narrowest attack surface, but bare-hostname browser
  visits get connection refused), comment the `80:8080/tcp` line in
  the compose and remove the matching upstream firewall rule.
- **Reference: behind Cloudflare Tunnel** (no host ports,
  `cloudflared` fronts the proxy) → `docker-compose.cf-tunnel.yml`.
  Genuinely simpler operationally (no VPS, no WG, no inbound pass
  rules); not used here because Cloudflare's edge TLS terminates the
  HTTPS connection on Cloudflare's infrastructure, exposing
  password-manager request bodies in plaintext to a third party. Fine
  for non-sensitive services. Pair with Phase 11 (Cloudflare Tunnel)
  if you pick this.
- **Reference: direct exposure with HTTP-01 ACME** (ports 80 + 443
  on the VM, port 80 required for Let's Encrypt validation) →
  `docker-compose.public-http01.yml`. Workable when home has a
  routable public IP and you'd rather not deal with Cloudflare API
  tokens for DNS-01. Not used here because home is CGNAT'd; the
  flavor would need the same VPS-passthrough wiring as `public-dns01`
  to actually be reachable.

Also place the poduser-side launcher script:

```bash
# Still as poduser:
cp scripts/poduser_scripts/start-containers.sh /home/poduser/vault/start-containers.sh
chmod 700 /home/poduser/vault/start-containers.sh
```

(The script `cd`s into `/home/poduser/vault/` hardcoded, that's why the
repo checkout has to be at exactly that path.)

## Phase 11, Cloudflare Tunnel (cf-tunnel flavour only)

The whole tunnel setup is **dashboard-driven**, you do not need to
install `cloudflared` locally, run `cloudflared tunnel login`, or use
any CLI flow. Cloudflare's "remote-managed" tunnels are configured
entirely from the web UI; the only artifact that crosses over to the
VM is a single token string that goes into `.env` as `CLOUD_TOKEN`.
The `cloudflared` container in `docker-compose.cf-tunnel.yml`
consumes that token and creates the outbound tunnel automatically.

Steps in your browser:

1. Go to [dashboard.cloudflare.com](https://dashboard.cloudflare.com)
   and sign in. If you don't have a domain on Cloudflare yet, register
   one (or transfer an existing one in) and complete the standard
   domain-onboarding flow until DNS is hosted by Cloudflare.
2. Open the **Zero Trust** dashboard (left sidebar →
   "Zero Trust", or directly at
   [one.dash.cloudflare.com](https://one.dash.cloudflare.com)).
3. **Networks → Tunnels → Create a tunnel** → connector type
   `Cloudflared` → name it (e.g., `vaultwarden-prod`) → **Save tunnel**.
4. The next screen shows install instructions for various platforms.
   **Ignore those**, you're not installing `cloudflared` on the host;
   the container in the compose file will run it. Just copy the
   **token** (the long string after `--token` in the displayed
   command). That string is `CLOUD_TOKEN` in your `.env`.
5. Still in the tunnel config, switch to the **Public Hostname** tab
   → **Add a public hostname**:
   - **Subdomain**: e.g. `vault` (whatever you want for the URL).
   - **Domain**: pick the domain you onboarded in step 1.
   - **Service Type**: `HTTP`.
   - **URL**: `bunkerweb:8080` (the container name + internal port, the
     tunnel terminates inside the Podman network).
   - Save.
6. Cloudflare automatically creates a proxied CNAME pointing
   `<subdomain>.<domain>` at the tunnel. Verify under **DNS** in the
   main Cloudflare dashboard that the record exists and the proxy
   icon is **orange** (proxied), not grey.

That's it. Once `CLOUD_TOKEN` is in `.env` and Phase 12 brings the
stack up, the `cloudflared` container connects outbound to Cloudflare,
the tunnel registers itself, and `https://<subdomain>.<domain>` starts
serving, no inbound ports opened on the VM, no DNS records to
manually create.

## Phase 11 alternate, Edge VPS + WireGuard (public-* flavours)

Use this instead of Phase 11 when the home ISP applies CGNAT (no
routable public IPv4 reaches your home connection) or you don't
want Cloudflare in the TLS-termination path. The current
production deployment is on `docker-compose.public-dns01.yml` with
this topology.

The full provisioning runbook lives in [`vps/README.md`](vps/README.md):
Hetzner Cloud CX23 in Falkenstein, Debian 13, SSH hardening, UFW,
WireGuard tunnel back to OPNsense, nginx as a raw TCP **stream
proxy** with **PROXY protocol** for real-IP preservation (no TLS
termination on the VPS), OPNsense WireGuard instance + peer +
interface assignment + firewall pass rules into the DMZ VLAN, plus
the Hetzner Cloud Console steps for setting the PTR records and
the DNS records (A + AAAA, grey cloud, NOT proxied) at the
registrar.

Skip ahead to Phase 12 once the VPS is provisioned, the WG tunnel
is healthy on both ends (`sudo wg show` shows recent handshakes),
the OPNsense pass rules are in place, and DNS resolution from
external returns the VPS's IPs (verify with
`dig +short vault.example.com @1.1.1.1`).

A small but load-bearing detail in that runbook: the Debian default
nginx site (`/etc/nginx/sites-enabled/default`) MUST be removed.
It ships with `listen 80 default_server;` and silently wins the
port-80 race against the stream block, with the only symptom being
nginx's default welcome page served on port 80 instead of the
forwarded traffic. Easy to miss, hard to debug after the fact.

The `vps/README.md` also documents the PROXY protocol setup that
preserves real client IPs through the full chain (VPS nginx ->
WG tunnel -> rootlessport SNAT -> BunkerWeb), so CrowdSec,
rate-limiting, country blacklist, and access-log forensic value
all operate on real visitor IPs rather than internal tunnel
addresses. Trade-off accepted: HTTP/3 over UDP/443 isn't exposed
since PROXY protocol is TCP-only; clients negotiate down to
HTTP/2 over TCP automatically.

The VPS also runs `crowdsec-firewall-bouncer-nftables` as a
**second** CrowdSec bouncer (alongside BunkerWeb's in-stack plugin
at home), pulling the same ban-decision stream from the home LAPI
over the WG tunnel and dropping banned IPs in nftables at the VPS
edge before they cross into home. The bouncer is pre-registered
on first home-side container boot via the
`BOUNCER_KEY_VPS_FW_BOUNCER` env var (keyed off
`CROWDSEC_VPS_BOUNCER_KEY` in `.env`), so the VPS side is just an
apt install + a config-file edit (api_url, api_key). Full procedure
in [`vps/README.md`](vps/README.md) § "CrowdSec bouncer (block
banned IPs at the VPS edge)"; the template config lives at
[`vps/crowdsec/crowdsec-firewall-bouncer.yaml`](vps/crowdsec/crowdsec-firewall-bouncer.yaml).
The matching OPNsense pass rule on the `VPS_TUNNEL` interface
(`10.10.10.1 -> 192.168.50.3:8080`) is in the firewall table in
the [VPS README](vps/README.md) and in the main
[Vaultwarden README](README.md) § "Inbound from the edge VPS via
WireGuard".

## Phase 12, First boot of the stack

(Commands below use `docker-compose.public-dns01.yml`, the flavor
actually running in this deployment. Substitute the filename of
whichever flavor you picked in Phase 10.)

```bash
# As poduser:
cd ~/vault/bunkerweb
podman-compose -f docker-compose.public-dns01.yml up -d
podman-compose -f docker-compose.public-dns01.yml logs -f bunkerweb
```

What to watch for on first boot, in order:

1. **BunkerWeb** pulls the nginx-ultimate-bad-bot-blocker UA list, the
   DB-IP MMDB, and DNSBL data. First pull takes a minute. If it hangs,
   Squid is blocking one of: `github.com`, `raw.githubusercontent.com`,
   `download.db-ip.com`. Cross-check `proxy-home/vault_domains_allow_proxy.txt`.
2. **ACME challenge fires.** For DNS-01 it calls the Cloudflare API,
   failing here usually means `CLOUDFLARE_API_TOKEN` is wrong or
   scoped wrong. For HTTP-01 it needs ports 80/443 reachable from the
   internet.
3. **Cert issued** → BunkerWeb reloads → the container goes healthy.
4. **CrowdSec** container pulls the `bunkerity/bunkerweb` collection
   on first start. Auto-enrolment with the console succeeds once
   `CROWDSEC_ENROLL_KEY` is valid.
5. **Vaultwarden** healthcheck (`curl -sf http://localhost:8080/alive`
   inside the container) goes green within ~30s.

`podman ps` should show `bunkerweb`, `crowdsec`, `vaultwarden`, and (for
`cf-tunnel` only) `cloudflared` all healthy.

Test the vault loads over HTTPS from your workstation. ModSecurity is
in `DetectionOnly` mode by default (see README §ModSecurity / OWASP CRS),
so it won't hard-block anything yet, but every rule match is logged
to `/srv/bw-logs/modsec_audit.log` for tuning.

## Phase 13, First real login

1. Browse to `https://vault.example.com/admin`, enter `ADMIN_TOKEN`
   from `.env`.
2. Create your first user from the admin panel (since
   `SIGNUPS_ALLOWED=false`).
3. Confirm the new-account email arrives. If it doesn't, SMTP is
   misconfigured, check `.env`'s SMTP_* group and verify
   `in-v3.mailjet.com:587` is reachable (firewall rule 6, direct
   bypass of Squid).
4. Log out of `/admin`. Log in as the normal user.
5. **Don't import the vault yet**, Phase 15 is where you restore it
   from the encrypted backup, which is also the only meaningful test
   that the restore path works.

## Phase 14, Cron + final manual `main.sh` dry run

Install both crontabs from the repo root:

```bash
# Root crontab, runs main.sh nightly at 05:35.
sudo crontab -u root /home/poduser/vault/bunkerweb/root_crontab.txt

# poduser crontab, runs start-containers.sh @reboot.
sudo crontab -u poduser /home/poduser/vault/bunkerweb/poduser_crontab.txt

# Verify:
sudo crontab -u root -l
sudo crontab -u poduser -l
```

The two files (`root_crontab.txt`, `poduser_crontab.txt` at the repo
root) contain exactly:

- `35 5 * * * /bin/bash -lc '/root/vault/main.sh' > /dev/null 2>&1`
- `@reboot /bin/bash -lc '/home/poduser/vault/start-containers.sh'`

Run `main.sh` once manually to confirm end-to-end **before** the first
scheduled run:

```bash
sudo /root/vault/main.sh
```

Expected sequence:

1. `backup.sh`, stops containers → tars `/srv/vw-data` → age-encrypts
   → minisign-signs → bundles binaries + manifest + DECRYPT.txt →
   restarts containers → 30-day retention sweep. Result lands at
   `/srv/backups/vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz`. Logs
   to `/srv/logs/backup/vault-backup-YYYY-MM-DD.log`. Exit codes
   10–14 on failure (see `EXIT_CODE_DESC` in `lib.sh`).
2. `docker-update.sh`, pulls latest images per service with 3× retry.
   Logs to `/srv/logs/docker/update-YYYY-MM-DD.log`. Pull failures
   log-and-continue. Exit code 20 only on compose-dir / stop-containers
   failure.
3. `system-update.sh`, `apt-get update / upgrade / dist-upgrade /
   autoremove`, ensures `unattended-upgrades` is enabled, preserves
   `sshd_config` via `UCF_FORCE_CONFFOLD=1`. Logs to
   `/srv/logs/system/system-autoupdate-YYYY-MM-DD.log`. Exit codes
   30–33.
4. `reboot.sh`, safety gates (containers stopped + apt/dpkg lock free),
   then **always reboots**. Exit code 40 only when a safety gate
   blocks the reboot. The reboot event is logged inline in
   `/srv/logs/main/main-YYYY-MM-DD.log` (the orchestrator log).

Final `STATUS:` line in `/srv/logs/main/main-*.log` summarises what
succeeded (`OK` / `DOCKER_UPDATE_FAILED_BACKUP_OK` / `SYSTEM_UPDATE_FAILED` /
etc.). Deadman ping fires at the end if `DEADMAN_URL` is set in
`lib.sh` (off by default, see `ideas.md` #2).

`main.sh` also writes a machine-readable JSON status log, one line per
phase plus a `phase=run` rollup, to
`/srv/logs/status/vault-maint-status.jsonl` (`emit_status` /
`emit_run_summary`; needs `jq` for the rollup). The `run` line is emitted
**before** the reboot so the Wazuh agent can ship it to the manager before
the box goes down (an exit-trap-after-reboot races the shutdown). If you've
wired the Wazuh maintenance pipeline (`vault-maint-agent.localfile.xml` +
`manager-maint-rules.xml` rules 100500-100502 + the maintenance
`<integration>` block, see `wazuh-home/README.md`), this manual run also
produces a #maintenance Discord report (green OK, since nothing failed).
Eyeball the JSON with
`sudo cat /srv/logs/status/vault-maint-status.jsonl | jq .`.

## Phase 15, Restore from backup (the actually-important phase)

This is where you verify the rebuild worked. Not theoretical, do it.

1. Grab the newest `vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz` from
   TrueNAS (or Hetzner if you're testing the second-tier path).
2. On your **workstation** (not the VM), unwrap the bundle. It contains
   the pinned `age` + `minisign` binaries (Linux + Windows), so you
   don't depend on whatever's on `PATH`:
   ```bash
   tar -xzf vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz
   ```
3. **Verify the signature first** (against your externally-stored
   `minisign.pub`, the bundle does NOT include a trusted pubkey by
   design):
   ```bash
   ./minisign -V -p /path/to/your/external/minisign.pub \
       -m vw-data-backup-YYYY-MM-DD.tar.gz.age
   ```
   Expected: `Signature and comment signature verified`. Anything else
   → **stop**, the bundle is tampered or you're looking at the wrong
   pubkey.
4. **Only after** the signature verifies, decrypt with age:
   ```bash
   ./age -d -i ~/vault/identity.txt vw-data-backup-YYYY-MM-DD.tar.gz.age \
       | tar -xzf -
   ```
5. Stop the stack on the VM:
   ```bash
   cd ~/vault/bunkerweb
   podman-compose -f docker-compose.public-dns01.yml down
   ```
6. Rsync the restored `vw-data/` into place:
   ```bash
   sudo rsync -a --delete /workstation/path/to/vw-data/ /srv/vw-data/
   sudo chown -R poduser:poduser /srv/vw-data
   sudo chmod -R go-rwx /srv/vw-data
   ```
7. Bring the stack back up and log in with your real master password.
   Confirm an entry you recognize.
   ```bash
   podman-compose -f docker-compose.public-dns01.yml up -d
   ```

If step 7 fails, your backup is broken. Fix it **before** you trust
this instance with real secrets.

> Idea #5 in `ideas.md` is a script that automates steps 1–7 (with the
> "split into `decrypt.sh` + `start-test.sh`" extension that fetches
> fresh `age` + `minisign` from GitHub at restore time, instead of
> trusting the bundled binaries). Worth implementing once the manual
> drill is well-rehearsed.

## Phase 16, CrowdSec console enrollment

The `CROWDSEC_ENROLL_KEY` from `.env` auto-enrols the instance on first
start. Log into [app.crowdsec.net](https://app.crowdsec.net) → Security
Engines → verify your instance is listed and reporting. Pull in any
community blocklists you want from the console.

Sanity check: make 20 bad login attempts in a row from a test machine.
CrowdSec should ban your IP within a minute, the BunkerWeb bouncer
should pick it up on the next 15-second poll, and you should get a
403. Unban via:

```bash
sudo su - poduser
podman exec crowdsec cscli decisions delete --ip <your-ip>
exit   # back to your previous shell
```

## Phase 17, ModSecurity / CRS tuning (still WIP)

The compose ships with `MODSECURITY_SEC_RULE_ENGINE: DetectionOnly`,
**nothing is being blocked**, every rule match is just logged to
`/srv/bw-logs/modsec_audit.log`. This is intentional; flipping to `On`
without exclusions in place will break Vaultwarden's API.

Per README §ModSecurity / OWASP CRS:

1. Exercise the stack normally for ≥1 week (login, vault edits,
   attachment uploads, sends, admin panel browse).
2. Tail `modsec_audit.log` for false positives. For each one, add an
   exclusion in:
   - `bunkerweb/custom-configs/modsec-crs/exclusions-before-crs.conf`
     for request-side rules (rule ID < 950)
   - `bunkerweb/custom-configs/modsec/exclusions-after-crs.conf` for
     response-side rules (95x / 98x)
3. Restart BunkerWeb after each exclusion:
   ```bash
   podman-compose -f docker-compose.public-dns01.yml restart bunkerweb
   ```
4. Once the audit log is consistently clean, flip
   `MODSECURITY_SEC_RULE_ENGINE` from `DetectionOnly` to `On`.
5. Then bump `blocking_paranoia_level` from PL1 to PL2 in
   `bunkerweb/custom-configs/modsec-crs/paranoia.conf` and re-tune.

Known exclusions table (currently just rule **911100** for
PUT/PATCH/DELETE method allowance) lives in the README, grow it as
you discover false positives.

## Phase 18, Post-deploy checklist

Tick all of these before declaring the rebuild done:

- [ ] `podman ps` shows 3 (`public-http01` / `public-dns01`) or 4
      (`cf-tunnel`) containers, all healthy.
- [ ] **If using the Edge VPS topology** (Phase 11 alternate): VPS
      shows `wg show` recent handshake, `nginx -t` passes, port 443
      claimed by the stream module (NOT the http default site,
      which must be removed: `ls /etc/nginx/sites-enabled/` should
      not contain `default`). OPNsense shows the WG peer connected
      and the pass rules for `10.10.10.1 → 192.168.50.3:{80,443,8080}`
      are in place (8080 = VPS bouncer to home CrowdSec LAPI). DNS
      records (A + AAAA) at the registrar point at the VPS's IPs
      with Cloudflare proxy DISABLED (grey cloud). PTR records at
      Hetzner Cloud Console are set to your public hostname for
      both IPv4 and IPv6.
- [ ] **If running the VPS-side CrowdSec bouncer**:
      `sudo systemctl status crowdsec-firewall-bouncer --no-pager`
      on the VPS shows `active (running)` with no LAPI connection
      errors. `sudo nft list table ip crowdsec` shows the
      `crowdsec-chain-input` + `crowdsec-chain-forward` chains
      hooked at priority -10 (and the `crowdsec-blacklists` set if
      LAPI has at least one ban). On the home VM:
      `podman exec crowdsec cscli bouncers list` shows
      `VPS_FW_BOUNCER` with a recent "Last API pull" timestamp.
- [ ] `https://vault.example.com` loads with a valid Let's Encrypt cert
      (check the issuer, not just the padlock).
- [ ] Login + vault unlock + view a real entry work end-to-end.
- [ ] Test email delivery: trigger a login email or password-change
      email; verify it arrives.
- [ ] First successful `main.sh` run visible at
      `/srv/logs/main/main-YYYY-MM-DD.log` with `STATUS: OK`.
- [ ] (If the Wazuh maintenance pipeline is wired) the run also wrote a
      `phase=run` line to `/srv/logs/status/*.jsonl` and posted a green
      #maintenance Discord report.
- [ ] `/srv/backups/vaultwarden-backup-bundle-YYYY-MM-DD.tar.gz` exists
      and is signed (the `.minisig` is bundled inside).
- [ ] TrueNAS shows the latest bundle (the `truenas-script.sh` cron
      pulled it via `fetcher`).
- [ ] Hetzner Storage Box shows the same bundle (second-tier
      replication ran).
- [ ] **Manual restore drill from Phase 15 succeeded**, signature
      verified, decryption succeeded, vault loaded with real data.
- [ ] CrowdSec console shows the instance reporting.
- [ ] Intentional bad-login test triggered a CrowdSec ban (Phase 16).
- [ ] ModSecurity audit log review scheduled (Phase 17 is a
      multi-week-long phase, not a one-shot).
- [ ] Wazuh agent (if matching the reference setup) is reporting to
      your `wazuh-home` manager and visible in the manager's agent
      inventory. If the LAN Pi-hole sidecar daemon + manager-side
      `wazuh-home/` config are in place, an `nslookup` from the Vault
      VM produces a rule-100251 (resolved), rule-100252 (Pi-hole
      policy block), or rule-100253 (upstream no-answer) alert
      within ~10 seconds (the sidecar's poll interval).
- [ ] Deadman's switch (if configured, `ideas.md` #2) is pinging on
      schedule.

---

## Recovery shortcuts (if this is a *re*build, not a first build)

If the old VM is still reachable:

1. `rsync` `/srv/vw-data`, `/srv/vw-logs`, `/srv/bw-logs`, `/srv/backups`,
   `/srv/logs`, the entire `/root/vault/` directory (scripts + crypto
   material), `.env`, and the `~/vault` repo checkout off to your
   workstation.
2. Stand up the new VM per Phases 1–9.
3. Drop the rsynced data into place:
   - `/srv/*` → restore directly to `/srv/`.
   - `/root/vault/` → restore directly to `/root/vault/`. Re-apply
     ownership: `sudo chown -R root:root /root/vault && sudo chmod 700 /root/vault`.
   - `.env` → `~/vault/bunkerweb/.env` on the poduser side.
4. Skip to Phase 12 (first boot), then Phase 14 (cron), then
   Phase 18 (checklist). You've avoided the restore-from-encrypted-bundle
   dance, which saves an hour, but **still do Phase 15 once a quarter**
   to make sure the encrypted-bundle path actually works.

If the old VM is gone: full rebuild, Phases 1 through 18, in order.

---

## What this runbook assumes you still have

If any of these are lost, the rebuild is much harder or impossible:

- **age private key (`identity.txt`)**, no backup bundle decrypts
  without it. Irrecoverable loss = irrecoverable loss of every
  historical backup.
- **minisign public key (`minisign.pub`)**, needed to verify any
  bundle's signature at restore time. The pubkey is **not** bundled
  inside backups (deliberately). Loss alone doesn't make backups
  unrecoverable, but it makes signature verification impossible, and
  you should not decrypt an unverified bundle.
- **Master password**, obvious but stating it: the root of the whole
  scheme. Vaultwarden cannot recover it for you.
- **Cloudflare account access**, needed to re-create tunnel / DNS.
- **Domain registrar access**, needed if DNS ever needs to move
  registrar.
- **TrueNAS access**, newest backup lives here first.

The `.env.template` in the repo lists every variable but not the
values. Keep the filled values somewhere that survives VM loss,
ideally in the vault itself (chicken-and-egg solved by writing them
down on paper too, for genuine disaster recovery).
