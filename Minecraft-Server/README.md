# Minecraft Server

Fabric-based Minecraft server with a **Velocity** proxy in front for real Mojang authentication and real-IP forwarding. Exposed publicly through the same VPS-nginx-stream pattern as Vaultwarden: TCP passthrough over WireGuard, **no TLS termination on the VPS**.

## Architecture

```
                    [VPS]                                       [Home VM]

Internet  ──TCP──>  nginx (proxy_protocol on)   ──WireGuard──>  velocity      :25565   (PROXY-protocol in)
                       :25565                                       │
                                                                    │  modern forwarding (signed handshake)
                                                                    ▼
LAN  ────────────────TCP──────────────────────────────────────> velocity-lan  :25566   (plain TCP in)
                                                                    │
                                                                    │  modern forwarding (signed handshake)
                                                                    ▼
                                                                minecraft     (Fabric + FabricProxy-Lite)
```

What this chain gives you:

* Real Mojang authentication at Velocity (verified Microsoft / Mojang session, pirate clients rejected).
* Player's real Mojang **UUID** forwarded to the backend via FabricProxy-Lite "modern" handshake. The whitelist works against online UUIDs as it would on a vanilla `online-mode=true` server.
* Player's real **IP** preserved end-to-end and visible in the Minecraft join log. No tunnel IP, no docker-bridge IP.
* Same security shape as a vanilla online-mode server, plus IP preservation and a clean separation between auth (proxy) and gameplay (backend).

Two Velocity instances run side by side:

| Service        | Host port | Listens for                                | When you use it                                                   |
| -------------- | --------- | ------------------------------------------ | ----------------------------------------------------------------- |
| `velocity`     | 25565     | TCP with PROXY-protocol header (from VPS)  | External players via `<vps_ip>` (MC default port, no `:25565`)    |
| `velocity-lan` | 25566     | Plain TCP                                  | LAN players who don't want to round-trip through the VPS          |

Both forward to the same backend over an internal docker bridge using a shared modern-forwarding secret. The backend has no published host ports of its own, so nothing reaches it without going through one of the two proxies first.

## Pinned versions

The committed `docker-compose.yml` ships **example** version pins:

* Minecraft: `26.1.2`
* Fabric Loader: `0.19.2`
* FabricProxy-Lite: latest stable on Modrinth (auto-downloaded at container start, version is whatever Modrinth has at boot)

These are just defaults; pick whatever versions suit your modpack. Change `VERSION` and `FABRIC_LOADER_VERSION` in the `minecraft` service's `environment:` block, then restart. The only hard constraint is that **every player's launcher must match exactly** — both MC version and Fabric Loader version — or they'll fail at the protocol handshake.

Clients can use any Fabric launcher (CurseForge App, Prism Launcher, Modrinth App, MultiMC). Make sure the instance matches whatever the compose is pinned to.

## File structure

```
Minecraft-Server/
├── README.md                       # this file
├── docker-compose.yml              # velocity + velocity-lan + minecraft (Fabric)
├── .env.template                   # RCON_PASSWORD slot, copy to .env
├── vps-nginx-snippet.conf          # paste into VPS /etc/nginx/streams.d/passthrough.conf
├── FabricProxy-Lite.toml.example   # copy to data/config/FabricProxy-Lite.toml, set secret
├── backup.sh                       # cron-able backup with RCON player warnings
├── crontab.txt                     # reference root crontab entry for backup.sh
├── velocity/
│   ├── velocity.toml               # VPS-facing (haproxy-protocol = true)
│   └── forwarding.secret.example   # copy to forwarding.secret, set secret
└── velocity-lan/
    ├── velocity.toml               # LAN-facing (haproxy-protocol = false)
    └── forwarding.secret.example   # copy to forwarding.secret, set SAME secret
```

**Local-only (gitignored)**, all derived from the `.example` templates above plus runtime artifacts:

* `velocity/forwarding.secret`, `velocity-lan/forwarding.secret`, `data/config/FabricProxy-Lite.toml` (the populated versions; must hold the same secret string)
* `.env` (your real RCON password)
* `data/` (world saves, libraries, generated server config, mods cache)
* `mods/` (your modpack jars; see "Adding mods" below)
* `backups/`, `logs/` (produced by `backup.sh`)

## First-time deployment

Touches three machines: the VPS (public edge), OPNsense (home firewall), the Minecraft host VM. Do them in any order; the test step needs all three.

### Minecraft host VM

```bash
cd ~/server

# Stage the secret-bearing files from their .example templates
cp velocity/forwarding.secret.example velocity/forwarding.secret
cp velocity-lan/forwarding.secret.example velocity-lan/forwarding.secret
mkdir -p data/config
cp FabricProxy-Lite.toml.example data/config/FabricProxy-Lite.toml

# Generate one shared secret and write it into all three places
SECRET=$(openssl rand -hex 32)
printf '%s' "$SECRET" > velocity/forwarding.secret
printf '%s' "$SECRET" > velocity-lan/forwarding.secret
sed -i "s/REPLACE_WITH_A_LONG_RANDOM_STRING/$SECRET/" data/config/FabricProxy-Lite.toml

# RCON password for the backup script and admin access
cp .env.template .env
nano .env   # set RCON_PASSWORD to something long

# Bring it up
docker compose up -d
docker compose logs -f
```

The first boot pulls Fabric Loader and MC at whatever versions you pinned in compose, downloads FabricProxy-Lite + Fabric API from Modrinth, copies any jars from `mods/` into `/data/mods`, and starts the world. Look for `Done (X.Xs)! For help, type "help"`.

#### Optional: server-list icon

Velocity auto-loads a file named `server-icon.png` from its working directory on start. It must be a **64×64 PNG**. Drop the file into both Velocity dirs:

```bash
cp server-icon.png velocity/server-icon.png
cp server-icon.png velocity-lan/server-icon.png
```

If your source is a JPG (or a PNG that isn't 64×64), convert and resize with ImageMagick first:

```bash
sudo apt-get install -y imagemagick
convert myicon.jpg -resize 64x64^ -gravity center -extent 64x64 -strip server-icon.png
```

What those flags do:

* `-resize 64x64^` scales so the shorter side becomes 64 px (so we have enough pixels to crop a square out of any aspect ratio).
* `-gravity center -extent 64x64` crops to a centered 64×64.
* `-strip` removes EXIF / colour-profile metadata.

Then re-run the two `cp` lines above and `docker compose restart velocity velocity-lan` for the new icon to load.

### VPS

Append the contents of `vps-nginx-snippet.conf` to `/etc/nginx/streams.d/passthrough.conf` (alongside any existing 80 / 443 stream blocks).

Widen the WireGuard `AllowedIPs` on the home peer so the VPS routes the Minecraft subnet through the tunnel. In `/etc/wireguard/wg0.conf`:

```
AllowedIPs = 10.10.10.2/32, 192.168.50.0/24, 192.168.70.0/24
```

Apply:

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'
sudo ip route add 192.168.70.0/24 dev wg0    # one-time; wg-quick installs this on future boots
sudo ufw allow 25565/tcp
```

### OPNsense

One firewall rule on the WireGuard tunnel interface:

* Interface: the WG tunnel (e.g. `VPS_TUNNEL`)
* Action: Pass
* Direction: In
* Protocol: TCP
* Source: `10.10.10.1/32` (the VPS WG tunnel IP)
* Destination: `192.168.70.2:25565` (the MC VM's LAN IP)

Save, apply. No gateways or policy-routes needed: the VPS terminates the TCP at nginx and re-originates a new connection over WG, so OPNsense sees normal stateful traffic from `10.10.10.1`. The real client IP is carried inside the Velocity handshake instead.

### Test

Two entry points to test, one per Velocity instance.

**VPS path (external):** open Minecraft (Fabric instance matching whatever versions you pinned in compose) and add server `<vps_public_ip>` (or your DNS name pointing at the VPS). Port 25565 is Minecraft's default, so no `:25565` suffix is needed. Connect.

**LAN-direct path:** from any device on your home LAN, add server `<mc_vm_ip>:25566` (e.g. `192.168.70.2:25566`). The explicit `:25566` is required because it's not the default Minecraft port. Connect.

On the VM, watch the join log:

```bash
docker compose logs minecraft | grep -i "logged in"
```

The join line should show the player's real IP:

* VPS path: real public IP, e.g. `Player1[/85.94.x.x:port] logged in with entity id 47 at (...)`
* LAN-direct path: real LAN IP, e.g. `Player1[/192.168.x.x:port] logged in ...`

If instead you see `/10.10.10.1` or a docker-bridge IP, modern forwarding isn't doing its job: the shared secret almost certainly doesn't match in all three files.

## Adding mods

Build your modpack in any Fabric launcher (CurseForge App, Prism, Modrinth App). Then on the VM:

```bash
# Copy server-compatible mods from your local instance.
# Example from PowerShell on Windows:
#   scp "C:\Users\you\curseforge\minecraft\Instances\<name>\mods\*.jar" main@<vm-ip>:~/server/mods/

docker compose restart minecraft
```

`itzg/minecraft-server` copies everything in `~/server/mods/` into `/data/mods` on each start.

Two things worth filtering out when copying:

* **`fabric-api-*.jar`**: itzg already auto-installs Fabric API as a FabricProxy-Lite dependency, matching whatever MC + Loader versions you pinned. Two copies may produce a "duplicate mod" error at startup; safest to leave the local copy out.
* **Client-only mods** (Sodium, Iris, Mod Menu, Xaero's Minimap, ReplayMod, anything purely rendering / shader / minimap): most are harmless on the server (Fabric just skips loading their client-only mixins and logs a warning); some, depending on how strictly they reference `net.minecraft.client.*`, may crash startup. If you want a smaller jar set and fewer warnings in the log, check each mod's "Environments" tag on Modrinth or CurseForge and skip anything labelled `Client` only. If you just copied everything and it boots cleanly, no harm done.

When updating mods later, clear out the staged copies first so removed mods actually go away:

```bash
docker compose down minecraft
rm -rf data/mods
# refresh ~/server/mods/ from your local launcher
docker compose up -d minecraft
```

## Alternative: using a public CurseForge modpack

If you'd rather run a pre-built modpack from CurseForge (All The Mods, Better Minecraft, etc.) instead of curating mods manually, swap `TYPE: "FABRIC"` for `TYPE: "AUTO_CURSEFORGE"`. itzg's image downloads the server pack zip directly from CurseForge and provisions everything from the modpack metadata.

### Compose changes

Replace:

```yaml
      TYPE: "FABRIC"
      VERSION: "26.1.2"
      FABRIC_LOADER_VERSION: "0.19.2"
```

with:

```yaml
      TYPE: "AUTO_CURSEFORGE"
      CF_PAGE_URL: "https://www.curseforge.com/minecraft/modpacks/<modpack-slug>/files/<file-id>"
      CF_API_KEY: ${CF_API_KEY}
```

* `CF_PAGE_URL` points to a specific **file** on the modpack's CurseForge page (Files tab → pick a version → copy that file's URL). itzg's image auto-detects whether the file is a "server pack" or a regular modpack and provisions accordingly.
* `CF_API_KEY` is a free CurseForge developer key. Generate at <https://console.curseforge.com/#/api-keys> and add it to `~/server/.env` alongside `RCON_PASSWORD`. `.env.template` already has the slot for it.

`VERSION` and `FABRIC_LOADER_VERSION` are no longer needed: the modpack metadata declares both. Updating the pack is just `CF_PAGE_URL` to a newer file ID + `docker compose restart minecraft`.

### Caveats

* **First boot is slow**: downloads + extracts the full modpack zip (often hundreds of MB) before the server starts.
* **Velocity integration must still work**: FabricProxy-Lite needs to be on the server for modern forwarding. If the modpack already ships with it, great. Otherwise keep `MODRINTH_PROJECTS: "fabricproxy-lite"` in the env so itzg layers it on top of the modpack's mods.
* **Forge modpacks**: FabricProxy-Lite is Fabric-only. For a Forge-based pack you'd need the Forge equivalent (e.g. `ProxyForge` mod). The `velocity.toml` `player-info-forwarding-mode = "modern"` line stays the same; only the backend bridge mod differs.
* **Client side**: players still install the matching modpack version on their launcher. CurseForge App makes this one-click for CurseForge-hosted packs; Prism / Modrinth App / MultiMC users have to import the pack from its CurseForge file URL.

For a self-curated set of mods built locally in any Fabric launcher, the manual `mods/` bind-mount approach (the default in this compose) is simpler and doesn't need a CurseForge API key.

## Rotating the shared secret

If the secret leaks (pasted in chat, committed by accident, etc.), generate a new one and apply it to all three files at once:

```bash
cd ~/server
SECRET=$(openssl rand -hex 32)
printf '%s' "$SECRET" > velocity/forwarding.secret
printf '%s' "$SECRET" > velocity-lan/forwarding.secret
sed -i "s/^secret = \".*\"/secret = \"$SECRET\"/" data/config/FabricProxy-Lite.toml

docker compose restart velocity velocity-lan minecraft
```

Any in-progress player sessions get dropped on restart; do it when nobody's mid-build.

## Backup

`backup.sh` does:

1. Announces a 5-minute stop sequence via RCON (`say` at 5 min, 2 min, 1 min, 10 s)
2. Stops the entire stack (`docker compose down`)
3. Tars `data/` into `~/server/backups/backup_<timestamp>.tar.gz`
4. Brings the stack back up
5. Writes per-day logs into `~/server/logs/backup-<date>.log`
6. Prunes log files older than 30 days

Wire it up via the `main` user's crontab. `crontab.txt` in this folder is the reference schedule that gets installed:

```cron
0 */6 * * * /bin/bash -lc '/home/main/server/backup.sh' > /dev/null 2>&1
```

That runs the backup every 6 hours. Adjust the schedule to taste (`0 4 * * *` for nightly at 04:00, for example) and install:

```bash
crontab -e
# paste the line above, save, exit
```

No `sudo` needed: the `main` user owns the script and the data dir, and is in the `docker` group, so it can run `docker compose` directly.

The script requires `RCON_PASSWORD` to be set in `~/server/.env` so the in-game warnings work. The 5-minute warning window means each backup run is ~5 min of downtime; if you want shorter, edit the `sleep` durations at the top of `backup.sh`.

## Notes

**Backend stays in offline mode.** The Minecraft container has `ONLINE_MODE=false` because Velocity does the Mojang handshake first; modern forwarding tells the backend to trust Velocity's verified UUID instead of re-doing the (now-impossible) session check. The whitelist still gates by real Mojang UUIDs because Velocity forwards them.

**Whitelist source of truth is the compose env vars.** With `OVERRIDE_SERVER_PROPERTIES=true` and `ENFORCE_WHITELIST=true`, the `WHITELIST` env var gets baked into `data/whitelist.json` on each boot. Edit the compose, restart, done. If you ever do `/whitelist add <name>` via RCON live, that change won't survive a restart unless you also add the name to the env var. Same logic for `OPS`.

**LAN-direct vs VPS-routed.** A LAN player can connect to either `192.168.70.2:25566` (via `velocity-lan`, explicit `:25566` required since it's not the default Minecraft port) or `<vps_public_ip>` (via the VPS, default port 25565, full round-trip). Both paths do real Mojang auth and modern forwarding. The LAN port exists to save ~30 ms of latency on local play and avoid bouncing through the VPS for no reason.
