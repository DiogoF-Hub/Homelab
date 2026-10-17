# Upgrading Wazuh (manager + agents)

Do this when the nightly **#maintenance** report shows `wazuh-agent → x.y.z`. Every Wazuh package is held (`apt-mark hold`), so nothing upgrades by itself.

**Order: `wazuh-home` first, then the agents.** An agent must never be newer than the manager, or the manager rejects it.

This is the short path for normal releases (e.g. 4.14.8 → 4.14.9). For a bigger jump (4.14 → 4.15, or 5.x), read the release notes and follow Wazuh's [all-in-one upgrade guide](https://documentation.wazuh.com/current/upgrade-guide/upgrading-central-components.html) instead, since those can change the index template and config files.

## 1. `wazuh-home` (server)

First take a **Proxmox snapshot** of `wazuh-home`: since 4.12 an indexer upgrade can't be undone by downgrading, so the snapshot is the way back.

```bash
sudo systemctl stop filebeat wazuh-dashboard wazuh-manager wazuh-indexer
sudo cp /etc/wazuh-indexer/jvm.options /etc/wazuh-indexer/jvm.options.old
sudo apt-get update
sudo apt-get install --allow-change-held-packages wazuh-indexer wazuh-manager wazuh-dashboard filebeat
sudo apt-mark hold wazuh-indexer wazuh-manager wazuh-dashboard filebeat   # the install drops the hold
```

If dpkg asks about a config file:
- `/etc/wazuh-indexer/jvm.options`: take the new one (`Y`), then put the heap back to 3 GB below.
- anything else (`opensearch_dashboards.yml`, `filebeat.yml`, ...): keep yours (`N`). The package's version is saved next to it as `.dpkg-dist` if you ever want to compare.

Check the heap, it must be 3g on both lines (the package resets it if it replaced the file):

```bash
sudo grep -E '^-Xm[sx]' /etc/wazuh-indexer/jvm.options
sudo sed -i 's/^-Xms.*/-Xms3g/; s/^-Xmx.*/-Xmx3g/' /etc/wazuh-indexer/jvm.options   # only if it isn't 3g
```

Start everything, indexer first. The `wazuh-indexer` package put its old bundled GeoIP database back, so copy the current one in before the indexer starts (see [README](README.md#geoip-database-manager-host); the nightly run would also catch it, a night later):

```bash
sudo cp /var/lib/GeoIP/GeoLite2-City.mmdb /usr/share/wazuh-indexer/modules/ingest-geoip/GeoLite2-City.mmdb
sudo systemctl daemon-reload
sudo systemctl restart wazuh-indexer && sleep 60
sudo systemctl restart wazuh-manager filebeat wazuh-dashboard
systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard    # 4x active
apt-mark showhold                                                           # all four
```

Log into the dashboard. The agents still show **active** on the old version; that's fine until step 2.

## 2. Each agent VM

Vault VM, LAN Pi-hole VM, and any other agent:

```bash
sudo apt-get update
sudo apt-get install --allow-change-held-packages wazuh-agent
sudo apt-mark hold wazuh-agent                   # the install drops the hold
systemctl is-active wazuh-agent                  # active
apt-mark showhold                                # wazuh-agent
```

`ossec.conf` (localfiles, agent name) is kept. If dpkg asks about `/etc/systemd/system/wazuh-agent.service`, take the new one (`Y`) unless you edited that unit yourself.

## 3. After

- [ ] Dashboard → Agents: everything **active** on the new version.
- [ ] A quick test, e.g. from your PC `curl -x http://192.168.173.2:3128 -sI https://example.org` → a #squid alert arrives.
- [ ] Next night's #maintenance report no longer shows `wazuh-agent → …`.
- [ ] Delete the Proxmox snapshot after a few normal days.

If the server upgrade breaks, roll `wazuh-home` back to the snapshot. Any agent already upgraded then has to go back to the old version too:

```bash
sudo apt-get install --allow-downgrades --allow-change-held-packages wazuh-agent=<old version>-1
```
