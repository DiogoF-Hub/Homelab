# Upgrading Wazuh (manager + agents)

Do this when the nightly **#maintenance** report shows `wazuh-agent → x.y.z`. Every Wazuh package is held (`apt-mark hold`), so nothing upgrades by itself.

**Order: `wazuh-home` first, then the agents.** An agent must never be newer than the manager, or the manager rejects it.

This is the short path for normal releases (e.g. 4.14.8 → 4.14.9). For a bigger jump (4.14 → 4.15, or 5.x), read the release notes and follow Wazuh's [all-in-one upgrade guide](https://documentation.wazuh.com/current/upgrade-guide/upgrading-central-components.html) instead, since those can change the index template and config files.

## 1. `wazuh-home` (server)

First take a **Proxmox snapshot** of `wazuh-home`: since 4.12 an indexer upgrade can't be undone by downgrading, so the snapshot is the way back.

Set the target version once (the one the #maintenance report showed, without the `-1`) and the indexer shortcuts from the README:

```bash
WZ=4.14.9
CERT="--cert /etc/wazuh-indexer/certs/admin.pem --key /etc/wazuh-indexer/certs/admin-key.pem"
IDX="https://127.0.0.1:9200"
```

Stop Filebeat and the dashboard, then let the indexer write everything to disk and stop it cleanly (Wazuh's own order: no shard moves, a flush, then the stop):

```bash
sudo systemctl stop filebeat wazuh-dashboard
sudo curl -sk $CERT -X PUT "$IDX/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
sudo curl -sk $CERT -X POST "$IDX/_flush"
sudo systemctl stop wazuh-manager wazuh-indexer
```

Install. Agents keep their events queued while the manager is down.

```bash
sudo cp /etc/wazuh-indexer/jvm.options /etc/wazuh-indexer/jvm.options.old
sudo apt-get update
apt-cache policy wazuh-manager | grep Candidate                 # must be $WZ-1
sudo apt-get install --allow-change-held-packages wazuh-indexer wazuh-manager wazuh-dashboard filebeat
```

If dpkg asks about a config file:
- `/etc/wazuh-indexer/jvm.options`: take the new one (`Y`), then put the heap back to 3 GB below.
- anything else (`opensearch_dashboards.yml`, `filebeat.yml`, `ossec.conf`, ...): keep yours (`N`). The package's version is saved next to it as `.dpkg-dist` if you ever want to compare.

Check the heap, it must be 3g on both lines (the package resets it if it replaced the file):

```bash
sudo grep -E '^-Xm[sx]' /etc/wazuh-indexer/jvm.options
sudo sed -i 's/^-Xms.*/-Xms3g/; s/^-Xmx.*/-Xmx3g/' /etc/wazuh-indexer/jvm.options   # only if it isn't 3g
```

Start the indexer alone, wait for it, then turn shard allocation back on:

```bash
sudo systemctl daemon-reload
sudo systemctl start wazuh-indexer && sleep 90
sudo curl -sk $CERT "$IDX/_cat/nodes?v"                       # one node, new version
sudo curl -sk $CERT -X PUT "$IDX/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"persistent":{"cluster.routing.allocation.enable":"all"}}'
sudo curl -sk $CERT "$IDX/_cluster/health?pretty" | grep status   # yellow is normal here (see README)
```

Start the manager, then refresh Filebeat's alerts template and Wazuh module to the new version (a release can change the field mappings; this doesn't touch the ISM retention policies):

```bash
sudo systemctl start wazuh-manager
sudo curl -so /etc/filebeat/wazuh-template.json \
  "https://raw.githubusercontent.com/wazuh/wazuh/v$WZ/extensions/elasticsearch/7.x/wazuh-template.json"
sudo chmod go+r /etc/filebeat/wazuh-template.json
curl -s https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.4.tar.gz | sudo tar -xz -C /usr/share/filebeat/module
sudo filebeat setup --pipelines
sudo filebeat setup --index-management -E output.logstash.enabled=false
sudo systemctl start filebeat wazuh-dashboard
```

Check:

```bash
systemctl is-active wazuh-indexer wazuh-manager filebeat wazuh-dashboard    # 4x active
sudo /var/ossec/bin/wazuh-control info | grep VERSION                       # v$WZ
sudo filebeat test output                                                   # talk to server ... OK
apt-mark showhold                                                           # still all four
```

Log into the dashboard. The agents still show **active** on the old version; that's fine until step 2.

## 2. Each agent VM

Vault VM, LAN Pi-hole VM, and any other agent (`wazuh-home` has none of its own: the manager is its own agent `000`, already upgraded in step 1):

```bash
sudo apt-get update
sudo apt-get install --allow-change-held-packages wazuh-agent
systemctl is-active wazuh-agent                  # active
apt-mark showhold                                # wazuh-agent still held
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
