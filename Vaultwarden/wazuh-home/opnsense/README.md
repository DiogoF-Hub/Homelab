# OPNsense firewall blocks → Wazuh → Discord

Every time OPNsense blocks traffic **from or to the Vault VM** (`192.168.50.3`), a message lands in the **#firewall** Discord channel. Two examples: the VM trying to reach the internet directly instead of going through Squid, or a host on another network trying a port on the VM that nothing allows.

OPNsense has no Wazuh agent. It sends its packet-filter log over syslog instead:

```
OPNsense filterlog ──UDP 514──> rsyslog on wazuh-home
                                  │ keeps only lines containing ,192.168.50.3,
                                  │ (everything else is dropped here)
                                  ▼
                       /var/log/opnsense/vault-filter.log
                                  │ tailed by the manager (localfile)
                                  ▼
             built-in pf decoder + rule 87701 (any block)
                                  │
                 100700 blocked FROM the Vault VM / 100701 blocked TO it
                                  ▼
                   custom-discord ──> #firewall (once per connection per 3 min)
```

The filter sits in **rsyslog, in front of Wazuh**, on purpose. Every syslog line Wazuh itself receives is stored in its archive, whatever the rules say. So if Wazuh listened on 514, the whole network's firewall traffic would end up in it.

## Files

| File | Goes to (on `wazuh-home`) |
|------|---------------------------|
| `rsyslog-opnsense.conf` | `/etc/rsyslog.d/10-opnsense.conf`: UDP 514 listener and the Vault VM filter |
| `logrotate-opnsense` | `/etc/logrotate.d/opnsense`: daily rotation, 7 kept |
| `manager-opnsense-localfile.xml` | appended to `/var/ossec/etc/ossec.conf`: the manager reads the filtered file |
| `manager-opnsense-rules.xml` | appended to `/var/ossec/etc/rules/local_rules.xml`: rules 100700 / 100701 |

The Discord side lives in [`../integrations/`](../integrations/): the `100700,100701` block in `manager-discord-integration.xml` and `format_firewall` in `custom-discord.py`.

## Setup

### 1. OPNsense: send the firewall log

1. **System → Settings → Logging → Remote**, click **+**:

   | Field | Value |
   |---|---|
   | Enabled | ✔ |
   | Transport | `UDP(4)` |
   | Applications | `filter (filterlog)` only |
   | Levels | nothing selected (= all) |
   | Facilities | nothing selected (= all) |
   | Hostname | `192.168.173.10` (wazuh-home) |
   | Port | `514` |
   | RFC5424 | **unchecked** (the classic format is the one Wazuh's syslog parser reads) |
   | Description | `wazuh-home` |

   **Save**, then **Apply**.
2. **Firewall → Settings → Advanced**, Logging section: tick **"Log packets matched from the default block rules"**. Most blocks against the Vault VM come from the implicit default deny, not from a rule of yours.
3. Any block rule of your own that should alert (e.g. the DMZ "block to other VLANs" rule) needs **Log** ticked on the rule itself.

### 2. wazuh-home: rsyslog filter

```bash
sudo apt install rsyslog
sudo mkdir -p /var/log/opnsense
sudo nano /etc/rsyslog.d/10-opnsense.conf      # paste rsyslog-opnsense.conf
sudo nano /etc/logrotate.d/opnsense            # paste logrotate-opnsense
sudo rsyslogd -N1 && sudo systemctl restart rsyslog
sudo ss -ulpn | grep ':514'                    # rsyslogd on 192.168.173.10
```

The config only accepts packets from `192.168.173.1` (OPNsense's LAN address; `ip route | grep default` on wazuh-home shows it). If yours differs, change it in `10-opnsense.conf`. If `ufw` is active on wazuh-home:

```bash
sudo ufw allow from 192.168.173.1 to any port 514 proto udp
```

Port 514 must belong to rsyslog, so the manager's `ossec.conf` must **not** have a `<remote>` block with `<connection>syslog</connection>`.

### 3. wazuh-home: Wazuh manager

1. Append `manager-opnsense-localfile.xml` to `/var/ossec/etc/ossec.conf`.
2. Append this integration block to the same file:
   ```xml
   <ossec_config>
     <integration>
       <name>custom-discord</name>
       <rule_id>100700,100701</rule_id>
       <alert_format>json</alert_format>
     </integration>
   </ossec_config>
   ```
3. Append `manager-opnsense-rules.xml` to `/var/ossec/etc/rules/local_rules.xml`.
4. Install the current `../integrations/custom-discord.py` as `/var/ossec/integrations/custom-discord`.
5. In Discord, create a `#firewall` channel and a webhook for it. Add it to `/var/ossec/integrations/discord-webhooks.json`:
   ```json
   "firewall": "https://discord.com/api/webhooks/..."
   ```
6. Restart. Do this **after** rsyslog has created the log file; if the file doesn't exist yet when the manager starts, the first lines are missed:
   ```bash
   sudo python3 -m json.tool /var/ossec/integrations/discord-webhooks.json >/dev/null && echo JSON OK
   sudo /var/ossec/bin/wazuh-analysisd -t && sudo systemctl restart wazuh-manager
   sudo grep vault-filter /var/ossec/logs/ossec.log | tail -1
   # expect: Analyzing file: '/var/log/opnsense/vault-filter.log'
   ```

## Test

**Blocked from the Vault VM.** On the Vault VM, skip the proxy and go straight to an IP:

```bash
curl --noproxy '*' -m 5 http://1.1.1.1         # times out
```

- `sudo tail -3 /var/log/opnsense/vault-filter.log` on wazuh-home: every line contains `192.168.50.3`.
- #firewall: **one** "🧱 Firewall blocked the Vault VM" (To `1.1.1.1:80`, interface `vlan050`). Running it again within 3 minutes posts nothing new. `/var/ossec/logs/custom-discord-fw-seen.json` holds the mute state.

Use an IP, not a hostname. A hostname that isn't on the Pi-hole allowlist resolves to `0.0.0.0`, so curl connects to the VM itself and never reaches the firewall. That test fires #dns instead.

**Blocked to the Vault VM.** From another machine, try a port nothing allows:

```bash
nc -vz -w 3 192.168.50.3 22                     # or: Test-NetConnection 192.168.50.3 -Port 22
```

→ "🛡️ Firewall blocked traffic to the Vault VM". If nothing arrives, check **Firewall → Log Files → Live View** in OPNsense. A **pass** line means that machine's network is allowed into the DMZ (e.g. OPNsense's default "allow LAN to any" rule), so there was no block to report.

## Notes

- **One message per source → destination:port/protocol per 3 minutes.** A blocked TCP connect logs several lines (SYN retries) and a port scan logs hundreds. The Wazuh dashboard still keeps every line.
- **Broadcast and multicast destinations are skipped** (DHCP, mDNS, ...). The default deny logs them, but they aren't connection attempts.
- **Allowed traffic to and from the Vault VM is kept too.** The rsyslog filter keeps every line with the VM's IP, pass or block. It's archived in Wazuh with no alert.
- **The Vault VM IP is hardcoded** in `rsyslog-opnsense.conf` and in rules 100700 / 100701, the same as in the DNS rules.
