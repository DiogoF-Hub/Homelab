# Edge VPS (TCP passthrough to home BunkerWeb)

The "front door" of the public-facing Vaultwarden stack. A small
Hetzner Cloud VPS in Falkenstein runs nginx as a raw TCP stream
proxy and forwards every byte of port 80 / 443 traffic over an
encrypted WireGuard tunnel back to the home BunkerWeb VM, which is
where TLS actually terminates.

## Why a VPS (and not the simpler `cf-tunnel` flavor)

> **What I'm running today**: `docker-compose.public-dns01.yml` paired
> with this VPS topology. The other compose flavors in the repo
> (`cf-tunnel.yml`, `public-http01.yml`) are kept as fully-working
> references for anyone reading this who's evaluating different
> deployment options for their own setup; I'm not actively running
> them. The comparison below is to explain WHY I picked the VPS path
> over the cf-tunnel path I considered first.

The cf-tunnel flavor (`docker-compose.cf-tunnel.yml`) runs a
`cloudflared` container that opens an outbound tunnel to Cloudflare
and exposes the site via Cloudflare's edge. No VPS to provision, no
WireGuard tunnel to maintain, no new inbound OPNsense pass rules to
add (cloudflared opens an outbound connection that goes out through
the existing outbound-allow rules, so the existing OPNsense firewall
posture is enough), no public IP rotation to worry about. Easier in
every way except one: **Cloudflare terminates TLS at its edge**. They see the plaintext request body of every HTTPS request
on its way to BunkerWeb, including `/admin` POST bodies (admin token in
plaintext), `/identity/connect/token` POST bodies (master-password
hash + refresh tokens), and every API call. For a generic web app this
is fine. For a password manager, having a third party in the cleartext
path of auth-credential traffic is an unacceptable threat-model
position.

The VPS topology trades operational simplicity for keeping TLS
termination on infrastructure I control, end-to-end. Concretely, what
the VPS approach delivers that cf-tunnel can't:

- **TLS terminates at home, not at any third party**: the VPS does
  raw TCP passthrough only. The Let's Encrypt private key lives in
  the home BunkerWeb container and is the only thing on the planet
  that can decrypt the TLS streams to plaintext. A VPS compromise
  yields ciphertext + traffic metadata, nothing decryptable.
- **No third-party visibility into request bodies**: even the
  hosting provider (Hetzner) only sees encrypted bytes flowing
  through their network. There is no plaintext interception layer
  anywhere between the client and home.
- **Public IP fully under my control**: the VPS IP can be rotated
  (re-deploy on a new instance, update DNS) without touching the
  home network or trusting a third-party edge to honor the change.
  No long-term pinning of the home IP to a password-manager
  hostname either.

The VPS path also incidentally **bypasses CGNAT** at home (which
would block any direct-exposure flavor like `public-http01` or
`public-dns01` from working on its own), but that's a side benefit;
even with a routable home IP, the no-third-party-TLS argument
above would still favour the VPS topology over `cf-tunnel`.

Things `cf-tunnel` does better (acknowledging the trade-off):

- One less machine to provision and patch
- Cloudflare's DDoS scrubbing at the edge (the VPS gets the raw
  attack traffic if anyone bothers to direct one)
- No WireGuard tunnel to monitor or re-establish on an outage
- Hidden origin IP (`cf-tunnel` doesn't advertise the VM's public
  IP anywhere; the VPS topology does, by definition)

Net assessment: for a password manager specifically, the VPS approach
wins because the alternative leaks plaintext credentials to a third
party. For other self-hosted services where TLS-at-edge isn't a
threat-model deal-breaker, `cf-tunnel` is genuinely easier.

## Architecture

```
External client (browser / Bitwarden client / scanner)
   |
   |  443/tcp, 80/tcp
   v
[Hetzner VPS - CX23, Falkenstein/fsn1]
  Public IPv4 + IPv6 (PTR set to vault.example.com)
  Debian 13 Trixie
  nginx stream { } - raw TCP passthrough with PROXY protocol, NO TLS termination
  crowdsec-firewall-bouncer-nftables - pulls bans from home LAPI, drops at the edge
   |
   |  WireGuard tunnel (UDP 51820, encrypted, point-to-point /30)
   |  VPS: 10.10.10.1   <->   OPNsense: 10.10.10.2
   v
[OPNsense]
  WireGuard endpoint
  Pass rules: 10.10.10.1 -> 192.168.50.3 on tcp/80 + tcp/443 (passthrough),
  plus tcp/8080 (VPS bouncer to home CrowdSec LAPI). All TCP only;
  UDP/443 deliberately not exposed since PROXY protocol is TCP-only.
  Routes traffic into the DMZ VLAN (vlan050, 192.168.50.0/24)
   |
   v
[BunkerWeb VM - 192.168.50.3 - DMZ VLAN]
  Terminates TLS (Let's Encrypt, DNS-01 ACME via Cloudflare API)
  WAF (ModSecurity + CrowdSec bouncer)
  Reverse-proxies to Vaultwarden container (backend Podman network)
   |
   v
[Vaultwarden]
```

**Compose flavor used**: `docker-compose.public-dns01.yml` on the
home BunkerWeb VM. The `cf-tunnel` flavor is incompatible with this
topology (cloudflared would replace the WG tunnel with its own
edge-routed one); the `public-http01` flavor would also work but
DNS-01 ACME is the natural fit since Cloudflare is already in the
DNS provider role.

### Key design decisions

- **Cloudflare = DNS only (grey cloud, NOT proxied)**. The A and
  AAAA records for the public hostname point at the VPS's IPs, with
  CF's orange-cloud proxying explicitly disabled. Enabling it would
  put Cloudflare back in the TLS-termination path with cleartext
  visibility into admin tokens, login hashes, and every byte of
  request bodies, the exact failure mode this whole architecture
  exists to avoid for a password manager.
- **DNS-01 ACME, not HTTP-01**. The ACME challenge runs out-of-band
  via the Cloudflare API; port 80 isn't required for cert issuance.
  Port 80 is still exposed (see compose comments) for the
  http -> https 301 redirect convenience, not for ACME.
- **Raw TCP passthrough, no application-layer awareness**. The VPS
  doesn't know it's serving Vaultwarden. Adding more services later
  is a per-port nginx stream block + matching UFW + OPNsense rule,
  no shared application state.

---

## Hetzner Cloud setup

### Instance

- **Type**: CX23 (current generation, AMD; specs visible at
  [hetzner.com/cloud](https://hetzner.com/cloud))
- **Location**: Falkenstein (fsn1), chosen for low latency to the
  home network in central Europe; pick the closest DC for your case
- **OS**: Debian 13 Trixie
- **Hostname**: `vault-deb13-fsn1` (convention: role-os-location)

### One-time Hetzner Console steps

1. **Set the PTR record** for both IPv4 and IPv6 to your public
   hostname (e.g. `vault.example.com`). In the Cloud Console:
   open the server, go to the "Networking" tab, click the gear icon
   next to each IP and set the rDNS to your hostname. Required for:
   - Mailjet's reverse-DNS check on outbound SMTP from BunkerWeb
     (if SMTP egress goes through the VPS; in this stack it does
     not, but the PTR alignment is good hygiene either way)
   - TLS clients that do reverse-lookup verification (rare but
     they exist)
   - Looking professional rather than `static.X.Y.Z.clients.your-isp.de`

2. **Optional: attach a Hetzner Cloud Firewall**. Either skip the
   cloud-level firewall entirely (UFW on the VPS does the same job)
   or attach one with the same allow rules as UFW below. If you
   attach one and forget to allow a port, troubleshooting is
   confusing because it operates above the OS layer (won't show
   in `nft list ruleset`). The OS-level UFW is sufficient for this
   setup.

### DNS records (in your registrar's NS, Cloudflare in this stack)

Two records, both proxied OFF (grey cloud):

| Type | Name | Value | Proxy | TTL |
|------|------|-------|-------|-----|
| A | `vault.example.com` | `<vps_public_ipv4>` | DNS only | Auto |
| AAAA | `vault.example.com` | `<vps_public_ipv6>` | DNS only | Auto |

The grey cloud is critical. See the "Cloudflare = DNS only" decision
above; the password-manager threat model rejects any third-party TLS
termination.

---

## Initial VPS setup (Debian 13)

### SSH hardening

Hardened on first boot, before anything else is reachable. Standard
public-VPS posture: SSH on a non-default port, key-based authentication
only, root login disabled, only the operational user permitted, short
failure window. Configured in `/etc/ssh/sshd_config` (or a drop-in
under `/etc/ssh/sshd_config.d/`).

The exact port number doesn't matter much (it's not a security control,
just noise reduction against drive-by scanners), but it does need to
match the UFW allow rule below.

### fail2ban for SSH

Belt-and-suspenders on top of key-only auth: ban any IP that fails
SSH auth too many times in a row, even though password auth is off
and `MaxAuthTries` is tight. The CrowdSec firewall bouncer further
below covers application-layer scanners (Vaultwarden bruteforce,
community blocklists, etc.); fail2ban specifically catches noisy
SSH scanners earlier and independently. On the VPS this is a
"second opinion" layer; the home VM runs the same setup.

**Prerequisite, rsyslog.** Debian 13 ships with journald-only
logging by default; `/var/log/auth.log` doesn't exist out of the
box. The jail config below points fail2ban at that file, so we
need rsyslog to populate it:

```bash
sudo apt install rsyslog -y
```

Once installed, sshd auth events start landing in `/var/log/auth.log`
(rsyslog's package default ships a rule that splits authpriv there).

**Install + configure fail2ban:**

```bash
sudo apt install fail2ban -y
sudo nano /etc/fail2ban/jail.local
```

Contents of `/etc/fail2ban/jail.local`:

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
`backend = auto` paired with an explicit `logpath` forces fail2ban
to file-poll `/var/log/auth.log` (which is why rsyslog matters; the
alternative `backend = systemd` reads journald directly and skips
the auth.log dependency, but the file-poll path is what's deployed
here).

Enable + start:

```bash
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status sshd
```

The last command should print the jail's current state (currently
banned IPs, total bans since fail2ban started, etc.) and confirms
the sshd jail is loaded.

### UFW firewall

Default deny inbound, explicit allow per service port:

```bash
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow <ssh_port>/tcp   # the SSH port chosen above
sudo ufw allow 51820/udp        # WireGuard
sudo ufw allow 80/tcp           # HTTP (passthrough; redirect-only, NOT ACME)
sudo ufw allow 443/tcp          # HTTPS passthrough (TCP only; HTTP/3 over UDP/443 is intentionally not exposed, see nginx/streams.d/passthrough.conf header)
sudo ufw enable
```

**Closing port 80 entirely is only an option with the
`docker-compose.public-dns01.yml` flavor on the home BunkerWeb VM**,
because DNS-01 ACME validates via the Cloudflare API and doesn't
need port 80. The `docker-compose.public-http01.yml` flavor
absolutely requires port 80 open for ACME HTTP-01 challenges, so
you can't drop it there.

If you're on `public-dns01` and want the narrowest surface (cost:
no http→https redirect, bare-hostname browser visits get connection
refused, external HTTP-probing tools can't reach you), omit the
`80/tcp` UFW rule, drop the matching OPNsense pass rule, drop the
port-80 server block from `nginx/streams.d/passthrough.conf`, and
comment the `- "80:8080/tcp"` line in
[`docker-compose.public-dns01.yml`](../docker-compose.public-dns01.yml)
on the BunkerWeb VM.

Verify after enabling:

```bash
sudo ufw status verbose
# should list <ssh_port>/tcp, 51820/udp, 80/tcp, 443/tcp ALLOW IN
```

### WireGuard (the home-tunnel side)

```bash
sudo apt install wireguard -y

# Generate keypair on the VPS
wg genkey | sudo tee /etc/wireguard/private.key \
  | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key

# Note the public key (output of the second command); you'll paste
# it into OPNsense when configuring the peer there.
sudo cat /etc/wireguard/public.key
```

Tunnel config: see [`wireguard/wg0.conf.template`](wireguard/wg0.conf.template).

Copy that template to `/etc/wireguard/wg0.conf` on the VPS, fill in
the `<vps_private_key>` (paste the contents of
`/etc/wireguard/private.key`) and `<opnsense_public_key>` (the public
key OPNsense generated for its end of the tunnel; see the OPNsense
section below for how to get it). Then:

```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show     # verify the peer is listed and a handshake occurred
```

A successful handshake shows `latest handshake: <a few seconds ago>`
and `transfer:` counters that increase over time.

### nginx (raw TCP stream proxy with PROXY protocol)

```bash
sudo apt install nginx libnginx-mod-stream -y
sudo mkdir -p /etc/nginx/streams.d
```

Two files to deploy from this folder:

1. [`nginx/streams.d/passthrough.conf`](nginx/streams.d/passthrough.conf)
   -> `/etc/nginx/streams.d/passthrough.conf` on the VPS.
2. [`nginx/nginx.conf.snippet`](nginx/nginx.conf.snippet) -> append
   to the bottom of `/etc/nginx/nginx.conf` on the VPS, OUTSIDE
   the existing `http {}` block.

Then **remove the Debian default site** so the http {} block doesn't
race the stream block for port 80:

```bash
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

Critical: `sites-enabled/default` ships with `listen 80 default_server;`.
If left enabled, nginx's http context wins port 80 and your stream
block silently does nothing; port 443 still works (no http
contender), but port 80 serves nginx's default welcome page instead
of forwarding to BunkerWeb. The only obvious symptom is that
`http://vault.example.com/` returns the welcome page instead of a
301 redirect to https.

Verify port 80 + 443 are now claimed by nginx and that the stream
config is the source:

```bash
sudo ss -tlnp | grep -E ':(80|443) '
sudo grep -rn 'listen 80' /etc/nginx/
# expected: ONLY /etc/nginx/streams.d/passthrough.conf:N
```

End-to-end smoke test (run from any external machine):

```bash
curl -sI -L http://vault.example.com/
```

You should see two responses: a `301 Moved Permanently` from
BunkerWeb (auto-configured because `AUTO_LETS_ENCRYPT: yes` implies
HTTPS-only enforcement), then a `200` after the curl follows the
redirect. The `Server:` header should NOT just be `nginx`. That
would mean the VPS's default page is responding (means the
`sites-enabled/default` removal step was missed).

---

## OPNsense setup (home end of the WG tunnel)

### Create the WireGuard instance

**VPN -> WireGuard -> Instances -> Add**:

| Field | Value |
|-------|-------|
| Name | `vps-tunnel` |
| Tunnel address | `10.10.10.2/30` |
| Listen port | (empty: OPNsense initiates outbound, so no listener) |
| MTU | (default, 1420 typically) |

Click the gear/key icon to generate a keypair. Note the **public
key**: it goes into the VPS's `/etc/wireguard/wg0.conf` as
`<opnsense_public_key>`.

### Add the VPS as a peer

**VPN -> WireGuard -> Peers -> Add**:

| Field | Value |
|-------|-------|
| Name | `vps` |
| Public key | (paste the VPS's public key, from `cat /etc/wireguard/public.key`) |
| Endpoint address | `<vps_public_ipv4>` |
| Endpoint port | `51820` |
| Allowed IPs | `10.10.10.1/32, 192.168.50.0/24` |
| Keepalive | `25` |
| Instances | `vps-tunnel` |

The Allowed IPs include both the VPS's tunnel IP and the home DMZ
subnet. The tunnel IP is for the peer relationship; the DMZ subnet
is the routable network the VPS will originate connections into
(via the proxy_pass to 192.168.50.3).

### Assign the WG interface

**Interfaces -> Assignments**: assign `wg0` (or whatever the WG
device is named) to a friendly name like `VPS_TUNNEL`.

**Interfaces -> [VPS_TUNNEL]**:

- Enable: checked
- IPv4/IPv6 Configuration Type: **None** (the address comes from
  the WireGuard instance, not from the OS interface)
- Block private/bogon networks: **unchecked** (the WG tunnel uses
  RFC1918, would be falsely classified as bogon)

### Firewall rules on the WG interface

**Firewall -> Rules -> VPS_TUNNEL -> Add**, one rule per port we
expose at the VPS. All have the same source (the VPS's WG IP) and
destination (the BunkerWeb VM). All three are TCP-only because
HTTP/3 / QUIC over UDP/443 is intentionally not exposed (PROXY
protocol is TCP-only and we need PROXY protocol for real-IP
preservation; see "Real client IP preservation" section below):

| # | Action | Protocol | Source     | Destination    | Port | Description                  | Log |
|---|--------|----------|------------|----------------|------|------------------------------|-----|
| 1 | Pass   | TCP      | 10.10.10.1 | 192.168.50.3   | 443  | VPS to Vault on 443          | Yes |
| 2 | Pass   | TCP      | 10.10.10.1 | 192.168.50.3   | 80   | VPS to Vault on 80           | Yes |
| 3 | Pass   | TCP      | 10.10.10.1 | 192.168.50.3   | 8080 | VPS bouncer to CrowdSec LAPI | Yes |

Rule #3 is for the VPS-side CrowdSec firewall bouncer to pull ban
decisions from the home LAPI; see "CrowdSec bouncer (block banned
IPs at the VPS edge)" section below. Omit it if you're not running
that bouncer (the home BunkerWeb plugin still enforces bans inline
at home, just not at the VPS edge).

If you've dropped port 80 (only an option on `public-dns01`, see UFW
section above), omit rule #2 along with the matching UFW + nginx
pieces on the VPS.

When adding new services later, append matching pass rules above any
default deny on this interface and add the matching nginx stream
block + UFW rule on the VPS.

### Sanity check

From the VPS, confirm the home-side reachability over the tunnel:

```bash
nc -zv 192.168.50.3 443       # TLS port reachable
nc -zv 192.168.50.3 80        # HTTP port reachable (if you exposed 80)
```

(Both TCP only; HTTP/3 over UDP/443 isn't exposed in this stack.)

(Don't bother with `ping`: ICMP doesn't have an explicit pass rule
on the VPS_TUNNEL interface, so it'll get default-denied by OPNsense
even when the actual TCP services are reachable. The `nc` checks
above target the actual service ports that the firewall rules
permit, which is the meaningful test.)

Both should succeed. If they don't, walk back through:
1. `sudo wg show` on the VPS: handshake recent? transfer counters
   incrementing?
2. OPNsense WireGuard status (VPN -> WireGuard -> Status): peer
   handshake recent there too?
3. OPNsense firewall log (Firewall -> Log Files -> Live View)
   filtered on source `10.10.10.1`. See if your `nc` attempts
   show as `block` (rule order wrong, default deny winning) or
   `pass`.

---

## Adding new services later

For each new TCP service to expose through this VPS:

1. **VPS nginx**: add a server block in
   `/etc/nginx/streams.d/passthrough.conf` (or a sibling file in
   `streams.d/`):

   ```nginx
   server {
       listen <port>;
       listen [::]:<port>;
       proxy_pass <backend_lan_ip>:<port>;
       # Add `proxy_protocol on;` here ONLY if the upstream service
       # speaks PROXY protocol. The Vaultwarden BunkerWeb upstream
       # does (and requires it for IP preservation); most non-HTTP
       # services don't.
   }
   ```

2. **VPS UFW**: open the port. `sudo ufw allow <port>/tcp`.

3. **OPNsense**: add a pass rule on the VPS_TUNNEL interface for
   `10.10.10.1 -> <backend>:<port>`.

4. Reload nginx: `sudo nginx -t && sudo systemctl reload nginx`.

UDP services are technically possible (just `listen <port> udp;` in the
server block) but PROXY protocol doesn't carry over UDP, so any UDP
service added through this VPS would have no real-IP preservation.
Acceptable for protocols where source-IP visibility doesn't matter
operationally; rule it out for anything where you want CrowdSec /
country-blacklist / per-IP rate limit to work.

---

## Real client IP preservation (PROXY protocol)

Raw TCP passthrough has a side effect: BunkerWeb at home would see the
WireGuard tunnel IP as the source of every external connection,
because the original client IP is at the TCP-socket layer that doesn't
survive the WG hop + Podman SNAT. This breaks every IP-based defense
on the home side (CrowdSec bans the wrong IP, rate limits become a
shared bucket, country blacklist can't geolocate an internal IP, access
logs are useless).

Fix: **PROXY protocol** between VPS nginx and BunkerWeb. PROXY is a
small TCP-layer header prepended to each upstream connection that
carries the original client IP+port through SNAT and tunnels.

The setup is on both ends:

- **VPS** sends PROXY: `proxy_protocol on;` on each `server` block in
  [`nginx/streams.d/passthrough.conf`](nginx/streams.d/passthrough.conf).
- **BunkerWeb** receives + uses it via four env vars in
  [`../docker-compose.public-dns01.yml`](../docker-compose.public-dns01.yml)
  (`USE_PROXY_PROTOCOL`, `USE_REAL_IP`, `REAL_IP_HEADER`, `REAL_IP_FROM`).
  Each var is documented inline in the compose file. Both
  `USE_PROXY_PROTOCOL` AND `USE_REAL_IP` are required; the first
  enables PARSING the header, the second enables USING the parsed IP.

**Trade-off**: HTTP/3 over UDP/443 is deliberately not exposed because
PROXY protocol is TCP-only. Clients negotiate down to HTTP/2 over TCP.
Minor extra RTT on first connect, no functional difference, in
exchange for IP preservation working uniformly across every byte that
reaches the home stack.

If you need to verify the chain is working, check `$remote_addr` in
recent BunkerWeb access-log entries; it should show real public IPs
rather than internal addresses. Same goes for `cscli alerts list`
on CrowdSec.

### How TCP, PROXY, and TLS layer together in the path

A useful mental model for what's happening on each request:

```
              TCP conn #1                         TCP conn #2
              (over the public internet)          (over the WG tunnel)

  client  <─────────────────────>   VPS   <─────────────────────>   BunkerWeb (home)
                                     |
                                     |  acts as a TCP byte forwarder:
                                     |  copies bytes between conn #1 and conn #2.
                                     |  adds a PROXY protocol header at the very
                                     |  start of conn #2 so BunkerWeb learns the
                                     |  original client IP.

  ─────────────────────────────────────────────────────────────────────────────
                         ↑  ONE TLS session end-to-end  ↑
             The TLS handshake (and all encrypted application data after it)
             is negotiated directly between the client and BunkerWeb. The VPS
             never holds the session keys, so it can't decrypt request /
             response bodies, HTTP headers, etc. It just shovels opaque
             encrypted bytes back and forth.
  ─────────────────────────────────────────────────────────────────────────────
```

So per request: **2 TCP connections, 1 end-to-end TLS session**. The VPS is
TCP-aware (knows the client's real IP, can add a PROXY header) but TLS-blind
(no session keys, no plaintext visibility). The PROXY header itself is in
plaintext on conn #2 because it sits BEFORE the TLS handshake starts, but
conn #2 travels through the encrypted WG tunnel so the header is effectively
encrypted on the public-internet portion of its path anyway.

---

## CrowdSec bouncer (block banned IPs at the VPS edge)

The VPS also runs a CrowdSec firewall bouncer
(`crowdsec-firewall-bouncer-nftables`) that pulls ban decisions from
the home CrowdSec LAPI every 10s over the WG tunnel and programs
nftables drop rules. Result: any IP that the home engine has banned
(BunkerWeb bruteforce scenarios, community blocklists, CrowdSec CTI,
manual `cscli decisions add`) gets dropped at the VPS network edge,
before the SYN ever crosses the WG tunnel or reaches BunkerWeb.

This is the second of two enforcement layers (the first is BunkerWeb's
in-stack CrowdSec plugin still 403-ing inline at home). Same engine
makes the decisions; both bouncers consume them. The VPS layer is
purely additive: if it ever stops working, BunkerWeb at home still
enforces; if BunkerWeb glitches mid-request, the VPS layer has
already dropped most known-bad IPs upstream.

### Why edge-drop on top of the in-stack bouncer

- **Banned IPs never enter the WG tunnel.** Saves bandwidth on both
  ends when a noisy scanner is hammering. With PROXY-protocol-preserved
  real IPs from the previous section, CrowdSec is already producing
  genuinely-actionable bans on real client IPs; they just only got
  enforced at home until this layer existed.
- **Defense in depth.** Two enforcement layers. If BunkerWeb's plugin
  ever has a bug, restarts mid-attack, or the home stack is briefly
  recreated, the VPS layer is still up and dropping.
- **Faster reaction at the edge.** Once the bouncer's 10s poll catches
  a new ban, the source IP is dead at the VPS for any further
  connection attempts; no per-request processing on the home side.
- **Scales to additional services.** If the VPS ever fronts more
  services beyond Vaultwarden via additional `streams.d/*.conf`
  blocks, all of them benefit from the same VPS-level CrowdSec layer
  without each needing its own in-stack bouncer.

### Install

The bouncer package isn't in default Debian repos. Add CrowdSec's
apt repo first:

```bash
curl -s https://install.crowdsec.net | sudo sh
sudo apt update
sudo apt install crowdsec-firewall-bouncer-nftables -y
```

That installs the bouncer (NOT the CrowdSec engine, which stays at
home; the VPS is a bouncer-only deployment). The package creates a
systemd unit `crowdsec-firewall-bouncer.service` enabled by default,
and a default config at
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` that points
at a non-existent local LAPI; that has to be edited to point at home.

### Configure

Replace the package's default config with the template in
[`crowdsec/crowdsec-firewall-bouncer.yaml`](crowdsec/crowdsec-firewall-bouncer.yaml),
or apply the three deltas inline:

1. `api_url: http://192.168.50.3:8080/` (was `http://127.0.0.1:8080/`)
2. `api_key:` paste the value of `CROWDSEC_VPS_BOUNCER_KEY` from the
   home VM's `.env`. The home CrowdSec container auto-registers a
   bouncer named `VPS_FW_BOUNCER` with this key on first start, via
   the `BOUNCER_KEY_VPS_FW_BOUNCER` env var on the crowdsec service
   in [`../docker-compose.public-dns01.yml`](../docker-compose.public-dns01.yml).
   No manual `cscli bouncers add` step needed.
3. Leave `set-only: false` (the package default) in both the ipv4 and
   ipv6 `nftables` blocks. With `nftables_hooks: [input, forward]`
   further down, banned IPs are then dropped on EVERY destination
   port at the VPS, not just 80/443. Includes SSH and WireGuard.
   This is the stricter posture (an attacker whose IP earned a ban
   can't fall back to probing SSH from the same address); see the
   "If you ban your own IP" subsection under Operational notes for
   the rescue path.

Reload and start:

```bash
sudo systemctl daemon-reload
sudo systemctl restart crowdsec-firewall-bouncer
sudo systemctl status crowdsec-firewall-bouncer --no-pager
```

Want `active (running)` and no errors about connecting to the LAPI.

### Verify

On the VPS, the bouncer creates two nftables tables on startup:

```bash
sudo nft list table ip crowdsec
sudo nft list table ip6 crowdsec6
```

Both should exist with at minimum an `input` and a `forward` chain
hooked at priority `-10` with a packet counter. If the LAPI has
non-zero ban decisions, you'll also see a `crowdsec-blacklists` set
populated with IPs and a `ip saddr @crowdsec-blacklists drop` rule in
each chain. If there are zero bans, the set isn't created yet,
that's normal; the bouncer materializes it on first decision.

On the home VM (vaultwarden):

```bash
podman exec crowdsec cscli bouncers list
```

Expect a row for `VPS_FW_BOUNCER` with a recent "Last API pull"
timestamp. The IP column shows a Podman-bridge address (10.89.x.x),
not the WG tunnel IP, because rootless Podman SNATs inbound
connections to its bridge gateway. The API key auth still works
fine; the IP shown is purely informational.

### End-to-end test

From the home VM, push a fake ban:

```bash
podman exec crowdsec cscli decisions add --ip 1.2.3.4 --duration 10m --type ban
```

Wait ~10s, then on the VPS:

```bash
sudo nft list table ip crowdsec | grep 1.2.3.4
```

The IP should appear in the `crowdsec-blacklists` set. Clean up:

```bash
podman exec crowdsec cscli decisions delete --ip 1.2.3.4
```

Within 10s the VPS bouncer pulls the deletion and the set empties.

---

## Operational notes

### When the VPS reboots

The systemd units (`wg-quick@wg0`, `nginx`, `ssh`) are all enabled,
so a reboot brings everything back automatically. Verify on first
boot after any maintenance:

```bash
sudo wg show                  # tunnel handshake recent?
sudo systemctl status nginx --no-pager | head -8
sudo ufw status verbose
```

### When the home internet drops

The WG tunnel will sit in "no recent handshake" until the home end
becomes reachable again. Once OPNsense is back online and reachable
from the VPS, the `PersistentKeepalive = 25` on the VPS side will
re-establish the handshake within ~25 seconds.

External clients hitting the VPS during the home outage get a TCP
RST after a brief connect timeout (nginx has nothing to forward to;
the upstream is unreachable). This is expected and correct
behavior; they retry, they get connected once home is back.

The CrowdSec firewall bouncer on the VPS side can't poll the home
LAPI during the outage. Default behavior is fail-open on stale
cache: previously-pulled decisions keep being enforced until they
expire, after which the VPS edge stops dropping banned IPs until
home is back. Acceptable trade-off, the BunkerWeb in-stack bouncer
is dead too during a home outage by definition, so "no enforcement"
during a home outage is consistent across both layers.

### If you ban your own IP

The VPS bouncer drops banned IPs on ALL destination ports (`set-only:
false` + `nftables_hooks: [input, forward]`), so a self-inflicted ban
locks you out of SSH at the VPS public IP too, not just HTTPS to
Vaultwarden. The rescue path works regardless:

1. SSH into the home Vault VM (`192.168.50.3`) from any LAN client.
   The home VM is on a private LAN; it doesn't go through the VPS,
   so the VPS bouncer can't see or affect that connection.
2. Delete the decision on the home LAPI:
   ```bash
   podman exec crowdsec cscli decisions delete --ip <your_banned_ip>
   ```
3. Within ~10s the VPS bouncer pulls the deletion and your IP comes
   back out of the nftables set. SSH from the previously-banned IP
   now works again.

If you don't have LAN access (e.g., you're traveling and the VPN IP
you usually use got banned), Hetzner's rescue console at
[robot.hetzner.com](https://robot.hetzner.com) is the fallback:
attach a rescue system, mount the disk, and either edit the bouncer
config to disable it temporarily or `systemctl mask
crowdsec-firewall-bouncer` from inside the chroot. More involved,
but always available.

CrowdSec's default `crowdsecurity/whitelists` parser auto-whitelists
RFC1918 + WG private addresses at the engine layer, so the WG tunnel
itself (`10.10.10.0/30`) can never get banned regardless of what
scenarios fire. Internal infrastructure traffic is safe from any
ban path, manual or scenario-driven.

### When the VPS is replaced (re-provisioned)

If you spin up a new VPS instance (e.g., to rotate the IP after
suspecting a compromise, or to upgrade plans), re-run this whole
runbook. The home OPNsense side stays put; only the VPS public
key, IPs, and PTR records change. Update the AAAA + A records in
DNS, update the OPNsense WG peer's "Public key" + "Endpoint
address" fields, and the tunnel re-establishes.

The CrowdSec bouncer needs to be re-installed too (it's a stateless
puller, so nothing precious lives on the old VPS): run the install
+ configure steps under "CrowdSec bouncer (block banned IPs at the
VPS edge)" again. The pre-registered `VPS_FW_BOUNCER` entry on the
home LAPI is keyed by the API key value, not by VPS identity, so
the same key keeps working on the new VPS, no `cscli` cleanup
needed on the home side.

### Updating nginx stream config

Edit `/etc/nginx/streams.d/passthrough.conf` directly on the VPS,
then:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

If you commit changes to this folder in the repo, copy the updated
template back to the VPS as part of the deploy. There's no
auto-sync; the in-repo files are documentation-of-record, not
config-management push.

---

## Cross-references

- [`../README.md`](../README.md): main Vaultwarden documentation,
  has the broader architecture context, log pipeline, and
  operational sections
- [`../REBUILD.md`](../REBUILD.md): full-stack rebuild runbook;
  the VPS is provisioned as part of a phase that references this
  folder
- [`../docker-compose.public-dns01.yml`](../docker-compose.public-dns01.yml):
  the home-side compose flavor that pairs with this VPS topology
  (port 80 + 443 exposure, DNS-01 ACME via Cloudflare API). Also
  defines the `BOUNCER_KEY_VPS_FW_BOUNCER` env var on the crowdsec
  service that pre-registers the VPS bouncer on container start
- [`crowdsec/crowdsec-firewall-bouncer.yaml`](crowdsec/crowdsec-firewall-bouncer.yaml):
  bouncer config to deploy at `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`
  on the VPS (only `api_url` + `api_key` need editing from this template)
- [`../proxy-home/`](../proxy-home/): for comparison, an
  outbound-side proxy in the same stack (Squid for Vault VM
  egress); same operational pattern (per-VM folder, configs +
  README)
- [`../wazuh-home/`](../wazuh-home/): same convention for the
  Wazuh manager VM
