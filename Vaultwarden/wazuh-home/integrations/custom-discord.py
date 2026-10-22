#!/usr/bin/env python3
"""
custom-discord: Wazuh manager -> Discord webhook integrator.

Runs on wazuh-home (the manager). Wazuh's integrator daemon
(wazuh-integratord) invokes it per matching alert as:

    custom-discord  <alert_file>  <api_key>  <hook_url>  [options]

We only use sys.argv[1] (the alert JSON file). The webhook is NOT taken
from ossec.conf's <hook_url>; instead each source routes to its own
channel via the WEBHOOKS map below, because every source (modsec / dns /
squid / ...) posts to a different Discord chat. ossec.conf just decides
WHICH alerts reach this script (one <integration> block per source,
scoped by <group>/<level>/<rule_id>); this script decides the channel,
the final data-field filter, and the embed.

WIRED SOURCES (the three pipelines configured today):
  - modsec : flattened ModSecurity events from the Vault VM sidecar
             (sidecar/vault/modsec-tail.py), tiered by manager-modsec-rules.xml.
             Posts band=high (rule 100303, level 11), the multi-vector
             attacks, without an @ (already blocked and banned), and a
             flagged RESPONSE (rule 100304, level 12) with an @, and a
             blocked REAL Bitwarden client (rule 100305, level 12, a likely
             false positive) with an @, muted per src+request for an hour;
             never the scanner noise below band=high.
  - dns    : Pi-hole FTL events from the Vault VM (manager-rules.xml).
             Pings on blocked=true EXCEPT status=blocked-external-null-reply
             (upstream NULL-reply noise), matching the dashboard filter.
  - squid  : Squid access log on the LAN Pi-hole VM (Wazuh built-in squid
             decoder). Pings on action=TCP_DENIED, an egress-allowlist
             denial from the locked-down Vault VM.

WEBHOOKS / SECRETS: the committed copy carries PLACEHOLDER URLs. The real
per-channel webhooks live in a side-file on the manager,
/var/ossec/integrations/discord-webhooks.json (JSON, mode 0640 root:wazuh,
not committed), whose keys override the placeholders at startup. So
re-installing this script never clobbers your URLs, and deliver() skips
any channel still on a placeholder (a half-configured manager just stays
quiet instead of erroring).

FUTURE SOURCES (not configured yet; add a WEBHOOKS key + an <integration>
block + un-comment the branch in main(), and verify the real alert shape
first, the way modsec was). Agent-down (504) and fail2ban are wired now.
CrowdSec is a bigger lift, it doesn't ship to Wazuh in this stack at all
(feeds the BunkerWeb plugin + VPS firewall bouncer), so that's a whole
separate pipeline, not just a formatter.

stdlib only (urllib, json, datetime, zoneinfo), no pip, no requests. One
optional Debian package, python3-maxminddb, for the local GeoIP lookup (see
geoip_local); without it the country comes from ip-api.com instead.
"""

import sys
import json
import time
import fcntl
import ipaddress
import re
import urllib.error
import urllib.request
from urllib.parse import quote
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# Optional Discord mention prepended to every notification (a role or
# user id like "<@&123...>" / "<@123...>"). Empty = no ping. Set it in the
# side-file below ("mention" key), not here.
MENTION = ""

LOCAL_TZ = "Europe/Luxembourg"

# Per-channel webhooks. The committed copy holds PLACEHOLDERS; the real
# URLs live in a side-file on the manager so re-installing this script
# never clobbers them. Fill them once in
# /var/ossec/integrations/discord-webhooks.json (mode 0640 root:wazuh), a
# JSON object like {"modsec": "https://discord.com/api/webhooks/...", ...}.
# Any keys it contains override the placeholders below; that file is not
# in the repo. Add a key here when wiring a new source (plus an
# <integration> block + a branch in main()).
WEBHOOKS = {
    "modsec":      "https://discord.com/api/webhooks/REPLACE_WITH_MODSEC_WEBHOOK",
    "dns":         "https://discord.com/api/webhooks/REPLACE_WITH_DNS_WEBHOOK",
    "squid":       "https://discord.com/api/webhooks/REPLACE_WITH_SQUID_WEBHOOK",
    "fail2ban":    "https://discord.com/api/webhooks/REPLACE_WITH_FAIL2BAN_WEBHOOK",
    "maintenance": "https://discord.com/api/webhooks/REPLACE_WITH_MAINTENANCE_WEBHOOK",
    "firewall":    "https://discord.com/api/webhooks/REPLACE_WITH_FIREWALL_WEBHOOK",
    "conffile":    "https://discord.com/api/webhooks/REPLACE_WITH_CONFFILE_WEBHOOK",
    "agents":      "https://discord.com/api/webhooks/REPLACE_WITH_AGENTS_WEBHOOK",
    # Nightly report of the other hosts, one #maintenance per Discord
    # category (the plain "maintenance" key is the Vault VM's).
    "maintenance-pihole": "https://discord.com/api/webhooks/REPLACE_WITH_PIHOLE_MAINTENANCE_WEBHOOK",
    "maintenance-wazuh":  "https://discord.com/api/webhooks/REPLACE_WITH_WAZUH_MAINTENANCE_WEBHOOK",
    "maintenance-vps":    "https://discord.com/api/webhooks/REPLACE_WITH_VPS_MAINTENANCE_WEBHOOK",
}
try:
    with open("/var/ossec/integrations/discord-webhooks.json") as _wf:
        WEBHOOKS.update(json.load(_wf))
except (FileNotFoundError, ValueError, OSError):
    pass    # no side-file (or unreadable) -> placeholders stay; deliver() skips them
# The side-file may also hold the mention, e.g. "mention": "<@123456789>",
# so it survives re-installing this script too.
MENTION = WEBHOOKS.pop("mention", MENTION)
# It may also map the hostnames BunkerWeb serves to a label for the modsec
# embed's Target field, kept there so the real domains stay out of the repo:
#   "modsec_targets": {"vault.example.com": "🔐 Vaultwarden",
#                      "example.com": "🌐 Apex site"}
# Every message's title links to its alert on the Wazuh dashboard, at the
# "dashboard_url" from the side-file (kept there so the address isn't in the
# repo); unset or still a placeholder = no links. Discord rejects a link
# whose host has no dot (https://wazuh-home -> HTTP 400, tested 2026-10-17),
# so it has to be an IP or a full name (wazuh-home.localdomain, or the
# Tailscale name to open the links from anywhere).
DASHBOARD_URL = str(WEBHOOKS.pop("dashboard_url", "")).rstrip("/")
ALERT_URL = ""      # set per alert in main(), added to the embed by deliver()
_targets = WEBHOOKS.pop("modsec_targets", {})
MODSEC_TARGETS = ({str(k).lower().rstrip("."): str(v) for k, v in _targets.items()}
                  if isinstance(_targets, dict) else {})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def country_flag(code):
    if not code or len(code) != 2:
        return ""
    return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in code.upper())


def format_timestamp(ts):
    try:
        dt = datetime.fromisoformat(ts.replace("+0000", "+00:00"))
        local = dt.astimezone(ZoneInfo(LOCAL_TZ))
        utc_str = dt.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%d %H:%M:%S UTC")
        local_str = local.strftime("%Y-%m-%d %H:%M:%S %Z")
        return f"{local_str} ({utc_str})"
    except Exception:
        return ts


def is_private_ip(ip):
    private_prefixes = (
        "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
        "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
        "172.27.", "172.28.", "172.29.", "172.30.", "172.31.", "192.168.",
        "127.", "::1", "fc", "fd", "fe80",
    )
    return ip.startswith(private_prefixes)


# MaxMind's GeoLite2-City as geoipupdate keeps it, the same data
# scripts/main.sh copies into the indexer for the dashboard's GeoLocation
# (the indexer's own copy sits in folders the wazuh user can't enter).
# Looking IPs up here keeps Discord and the dashboard in agreement, and
# keeps attacker IPs on the box.
GEOIP_DB = "/var/lib/GeoIP/GeoLite2-City.mmdb"


def geoip_local(ip):
    """
    Country/city from the local GeoLite2-City file, in ip-api's key names.
    Fields are empty when the IP isn't in the database (then it shows as
    Unknown, no outside lookup). Returns None only when the lookup can't run
    at all: python3-maxminddb missing, or the file unreadable by the wazuh
    user. resolve_geo then falls back to ip-api.com.
    """
    try:
        import maxminddb
        reader = maxminddb.open_database(GEOIP_DB)
    except Exception:
        return None
    try:
        rec = reader.get(ip) or {}
    except ValueError:      # not an IP address
        rec = {}
    finally:
        reader.close()
    country = rec.get("country") or {}
    city = rec.get("city") or {}
    region = (rec.get("subdivisions") or [{}])[0]
    return {
        "country":     country.get("names", {}).get("en", ""),
        "countryCode": country.get("iso_code", ""),
        "city":        city.get("names", {}).get("en", ""),
        "regionName":  region.get("names", {}).get("en", ""),
    }


def geoip_lookup(ip):
    """
    Fallback when geoip_local can't run: best-effort country/city from
    ip-api.com (free tier, HTTP only). Requires manager egress to
    ip-api.com:80. Fails soft to {} so the embed just omits geo if there's
    no egress or the lookup errors.
    """
    url = f"http://ip-api.com/json/{ip}?fields=country,countryCode,city,regionName"
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            if r.status == 200:
                return json.loads(r.read().decode("utf-8"))
    except Exception:
        pass
    return {}


def resolve_geo(src_ip, geo):
    """
    Build (country_display, location) from Wazuh's GeoLocation block if
    present (it never is for integrations: the indexer adds it after this
    script ran), else the local GeoLite2 file, else ip-api.com when the
    local lookup can't run, else a private/unknown label.
    """
    country = geo.get("country_name", "")
    country_code = geo.get("country_code2", "")
    city = geo.get("city_name", "")
    region = geo.get("region_name", "")

    if not country and src_ip not in ("N/A", "") and not is_private_ip(src_ip):
        fb = geoip_local(src_ip)
        if fb is None:
            fb = geoip_lookup(src_ip)
        country = fb.get("country", "")
        country_code = fb.get("countryCode", "")
        city = fb.get("city", "")
        region = fb.get("regionName", "")

    flag = country_flag(country_code)
    if flag and country and country_code:
        country_display = f"{flag} {country} ({country_code})"
    elif country:
        country_display = country
    elif is_private_ip(src_ip):
        country_display = "Private/Internal IP"
    else:
        country_display = "Unknown"

    if city and region:
        location = f"{city}, {region}"
    elif region:
        location = region
    elif city:
        location = city
    else:
        location = "N/A"

    return country_display, location


def modsec_target(hostname):
    """
    Which site a ModSecurity hit was aimed at, from the event's `hostname`
    (the host the client asked for, so attacker-controlled: shown in a
    code span, backticks stripped, capped at 100 chars). A name listed in
    MODSEC_TARGETS gets its label; a bare IP is called out as such; any
    other name is "Unknown host" once MODSEC_TARGETS is filled in, and
    shown as-is before that.
    """
    raw = str(hostname or "").strip()
    if not raw:
        return "⚠️ No hostname"
    host = raw.lower()
    if host.startswith("["):            # [v6] or [v6]:port
        host = host[1:].split("]", 1)[0]
    elif host.count(":") == 1:          # name:port or v4:port
        host = host.split(":", 1)[0]
    host = host.rstrip(".")
    shown = "`{}`".format(raw.replace("`", "")[:100])

    if host in MODSEC_TARGETS:
        return f"{MODSEC_TARGETS[host]} ({shown})"
    try:
        ipaddress.ip_address(host)
        return f"⚠️ Direct IP ({shown})"
    except ValueError:
        pass
    return f"⚠️ Unknown host ({shown})" if MODSEC_TARGETS else shown


# CRS "attack-*" tag suffixes (the sidecar's `attacks` field) in words.
# An unknown one is shown as-is.
CRS_ATTACK_NAMES = {
    "protocol":          "Protocol violation",
    "lfi":               "Path traversal / file access",
    "rfi":               "Remote file inclusion",
    "rce":               "Remote command execution",
    "injection-php":     "PHP injection",
    "injection-generic": "Code injection",
    "injection-java":    "Java injection",
    "xss":               "Cross-site scripting (XSS)",
    "sqli":              "SQL injection",
    "session-fixation":  "Session fixation",
    "disclosure":        "Information leak",
    "reputation-scanner":   "Known scanner",
    "reputation-scripting": "Scripting tool",
    "generic":           "Generic attack",
}


def _code(text, limit=64):
    """Client-controlled text as an inline code span: no backticks, capped."""
    return "`{}`".format(str(text).replace("`", "")[:limit])


def _modsec_detail_fields(data):
    """
    The "what did they try" fields of a modsec embed, from the sidecar's
    attacks / rule_msgs / matched_in. Events from before the sidecar shipped
    them just get none of these fields.
    """
    fields = []
    attacks = [a for a in str(data.get("attacks") or "").split(",") if a]
    if attacks:
        fields.append({"name": "Attack types", "inline": False,
                       "value": " · ".join(CRS_ATTACK_NAMES.get(a, a) for a in attacks)[:1024]})
    msgs = [m.strip() for m in str(data.get("rule_msgs") or "").split(" | ") if m.strip()]
    if msgs:
        shown = msgs[:5]
        value = "\n".join(f"• {m[:150]}" for m in shown)
        if len(msgs) > len(shown):
            value += f"\n… +{len(msgs) - len(shown)} more"
        fields.append({"name": "What matched", "value": value[:1024], "inline": False})
    where = [w for w in str(data.get("matched_in") or "").split(",") if w]
    if where:
        fields.append({"name": "Where", "inline": False,
                       "value": ", ".join(_code(w) for w in where)[:1024]})
    return fields


# ---------------------------------------------------------------------------
# Embed formatters (one per wired source)
# ---------------------------------------------------------------------------

# A client that trips a rule deterministically (an unlucky refresh token
# retried in the background, 2026-09) would otherwise ping on every retry,
# so rule 100305 posts once per src + request + rules per MODSEC_FP_MUTE_SECONDS.
# Same fail-open state file approach as the firewall mute.
MODSEC_FP_SEEN_FILE = "/var/ossec/logs/custom-discord-modsec-fp-seen.json"
MODSEC_FP_MUTE_SECONDS = 3600
_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

def _modsec_fp_key(data):
    """Same client IP, same request shape (item UUIDs collapsed), same rules."""
    path = _UUID_RE.sub("<uuid>", str(data.get("path", "")))
    return f"{data.get('srcip', '')}|{data.get('method', '')} {path}|{data.get('rule_ids', '')}"


def format_modsecurity(alert):
    """
    Discord embed from a flattened modsec event: rule 100303 (band=high),
    rule 100304 (the response was flagged, outbound_score > 0), or rule
    100305 (a real Bitwarden client got blocked, a likely false positive).
    Reads the clean fields the sidecar emits; no full_log scraping.
    """
    data = alert.get("data", {})
    geo = alert.get("GeoLocation", {})
    agent = alert.get("agent", {})

    src_ip = data.get("srcip", "N/A")
    method = data.get("method", "N/A")
    path = data.get("path", "N/A")
    score = data.get("anomaly_score", "N/A")
    outbound = str(data.get("outbound_score") or "0")
    response_flagged = outbound not in ("", "0")
    rule_ids = ",".join(dict.fromkeys(r for r in str(data.get("rule_ids") or "").split(",") if r)) or "N/A"
    unique_id = data.get("unique_id", "")
    engine = data.get("engine", "N/A")
    http_code = data.get("http_code", "N/A")
    target = modsec_target(data.get("hostname"))
    agent_name = agent.get("name", "N/A")
    timestamp = alert.get("timestamp", "N/A")
    client = " ".join(str(data.get(k)) for k in ("client_name", "client_version") if data.get(k))
    real_client = str((alert.get("rule") or {}).get("id")) == "100305"

    country_display, location = resolve_geo(src_ip, geo)

    # In DetectionOnly the score is what modsec WOULD block; in On it's
    # what it DID block. Make that explicit. ModSecurity v3 reports the
    # SecRuleEngine On setting as "Enabled" in the audit log.
    if engine in ("On", "Enabled"):
        enforced = "On (blocked)"
    elif engine == "DetectionOnly":
        enforced = "DetectionOnly (would block)"
    else:
        enforced = str(engine)

    if real_client:
        # Rule 100305: an official Bitwarden client got a 403/400 from modsec.
        # Someone's save / sync / login just failed; find the rule and the
        # variable (Where), then grep the Audit ID on the Vault VM.
        title, color = "🛑 ModSecurity , blocked a Bitwarden client (likely false positive)", 10181046  # purple
    elif response_flagged:
        # Rule 100304: what the server SENT BACK looked like a leak, and the
        # response was blocked. Either a real leak or a false positive
        # breaking a real client.
        title, color = "🔥 ModSecurity , suspicious response (blocked)", 15105570  # orange
    else:
        title, color = "🚨 ModSecurity , high-severity attack", 15158332        # red
    extra = [{"name": "Outbound score", "value": outbound, "inline": True}] if response_flagged else []
    if client:
        extra.append({"name": "Client", "value": _code(client), "inline": True})
    if real_client and data.get("user_agent"):
        extra.append({"name": "User-Agent", "value": _code(data.get("user_agent"), 160), "inline": False})

    return {
        "title": title,
        "color": color,
        "fields": extra + [
            {"name": "Agent",         "value": agent_name,           "inline": True},
            {"name": "Source IP",     "value": src_ip,               "inline": True},
            {"name": "Country",       "value": country_display,      "inline": True},
            {"name": "Location",      "value": location,             "inline": True},
            {"name": "HTTP code",     "value": str(http_code),       "inline": True},
            {"name": "Anomaly score", "value": str(score),           "inline": True},
            {"name": "Target",        "value": target,               "inline": False},
            {"name": "Request",       "value": f"`{method} {path}`", "inline": False},
        ] + _modsec_detail_fields(data) + [
            {"name": "Engine",        "value": enforced,             "inline": True},
            {"name": "Audit ID",      "value": _code(unique_id) if unique_id else "N/A", "inline": True},
            {"name": "CRS rules",     "value": f"`{rule_ids}`",      "inline": False},
        ],
        "footer": {"text": format_timestamp(timestamp)},
    }


def format_dns(alert):
    """
    Discord embed from a Pi-hole FTL event (rules 100252 / 100253). The
    client is always the Vault VM (internal), so no GeoIP, the signal is
    WHICH domain the locked-down VM tried to resolve and why it was denied.
    """
    data = alert.get("data", {})
    agent = alert.get("agent", {})
    timestamp = alert.get("timestamp", "N/A")

    return {
        "title": "🛑 Vault VM DNS blocked",
        "color": 15844367,  # amber
        "fields": [
            {"name": "Query",  "value": f"`{data.get('query', 'N/A')}`", "inline": False},
            {"name": "Type",   "value": str(data.get("qtype", "N/A")),   "inline": True},
            {"name": "Status", "value": str(data.get("status", "N/A")),  "inline": True},
            {"name": "Client", "value": data.get("srcip", "N/A"),        "inline": True},
            {"name": "Agent",  "value": agent.get("name", "N/A"),        "inline": True},
        ],
        "footer": {"text": format_timestamp(timestamp)},
    }


def format_squid(alert):
    """
    Discord embed from a Squid access-log event (Wazuh built-in squid
    decoder), action=TCP_DENIED, the Vault VM hit an egress-allowlist
    denial. Field names (data.url / data.action / data.id / data.srcip)
    are Wazuh's standard squid-decoder output; VERIFY against a real
    TCP_DENIED alert and adjust if your decoder names them differently.
    """
    data = alert.get("data", {})
    agent = alert.get("agent", {})
    timestamp = alert.get("timestamp", "N/A")

    return {
        "title": "🧱 Squid egress denied",
        "color": 15844367,  # amber
        "fields": [
            {"name": "URL",       "value": f"`{data.get('url', 'N/A')}`", "inline": False},
            {"name": "Action",    "value": str(data.get("action", "N/A")), "inline": True},
            {"name": "HTTP code", "value": str(data.get("id", "N/A")),     "inline": True},
            {"name": "Client",    "value": data.get("srcip", "N/A"),       "inline": True},
            {"name": "Agent",     "value": agent.get("name", "N/A"),       "inline": True},
        ],
        "footer": {"text": format_timestamp(timestamp)},
    }


# --- maintenance: the nightly run summary (rules 100501 / 100502) -----------

def _maint_cap_list(csv, limit=20):
    """Comma-joined names -> readable, capped list (Discord field max 1024c)."""
    if not csv:
        return "none"
    items = csv.split(",")
    if len(items) <= limit:
        return ", ".join(items)
    return ", ".join(items[:limit]) + f"  … (+{len(items) - limit} more)"

# Release notes per compose service, linked when its image was updated.
RELEASE_NOTES = {
    "vaultwarden":     "https://github.com/dani-garcia/vaultwarden/releases",
    "bunkerweb":       "https://github.com/bunkerity/bunkerweb/releases",
    "crowdsec":        "https://github.com/crowdsecurity/crowdsec/releases",
    "cloudflared":     "https://github.com/cloudflare/cloudflared/releases",
    "crowdsec-web-ui": "https://github.com/TheDuffman85/crowdsec-web-ui/releases",
    # Pi-hole VM (compose service names, as its main.sh reports them).
    # docker-pi-hole, not pi-hole/pi-hole: the pihole/pihole image follows
    # docker-pi-hole's releases, each listing its Core / FTL / Web versions.
    "pihole":          "https://github.com/pi-hole/docker-pi-hole/releases",
    "dnsproxy":        "https://github.com/AdguardTeam/dnsproxy/releases",
}

def _maint_images(data):
    """'Docker images updated' value: one line per image with old -> new
    version (images_detail, ';'-separated) and a release-notes link; falls
    back to the plain name list from older runs."""
    detail = data.get("images_detail", "")
    names = data.get("images_updated", "")
    if not detail and not names:
        return "none"
    lines = []
    # No versions (the Pi-hole VM, older Vault runs): one line per name.
    for entry in (detail.split(";") if detail else names.split(",")):
        service = entry.split(":", 1)[0].strip()
        link = RELEASE_NOTES.get(service)
        lines.append(f"{entry.strip()} ([release notes]({link}))" if link else entry.strip())
    return "\n".join(lines)[:1024]

def images_were_updated(alert):
    return bool(alert.get("data", {}).get("images_updated"))

def format_maintenance(alert):
    """
    Discord embed from the nightly `run` summary event. main.sh rolls the
    per-phase status lines into one event with these data.* fields. Color +
    icon track the overall status; the @ is decided by the caller (on
    degraded/fail, or when a container image was updated), not here.
    """
    data = alert.get("data", {})
    ts = alert.get("timestamp", "N/A")
    status = data.get("status", "unknown")
    images_updated = images_were_updated(alert)

    color = {"ok": 3066993, "degraded": 15844367, "fail": 15158332}.get(status, 10070709)
    icon = {"ok": "🟢", "degraded": "🟠", "fail": "🔴"}.get(status, "⚪")
    if status == "ok" and images_updated:
        color, icon = 3447003, "🔵"    # clean run, but new images go live at this reboot

    backup = data.get("backup_status", "N/A")
    size = data.get("backup_size", "")
    backup_val = f"{backup} ({size})" if size else backup
    images = data.get("images_updated", "")

    fields = [
        {"name": "Backup", "value": backup_val, "inline": True},
        {"name": "Reboot", "value": data.get("reboot_status") or "scheduled", "inline": True},
        {"name": "Docker images updated", "value": _maint_images(data), "inline": False},
    ]
    if images:
        fields.append({
            "name": "🐳 New images start at this reboot",
            "value": "Check the vault loads and logins/sync work once the VM is back.",
            "inline": False,
        })

    pulls = data.get("pull_failures", "")
    if pulls:
        fields.append({"name": "⚠️ Docker pull FAILED", "value": pulls.replace(",", ", "), "inline": False})

    fields.append({
        "name": f"APT upgraded ({data.get('apt_count', '0')})",
        "value": _maint_cap_list(data.get("apt_upgraded", "")),
        "inline": False,
    })

    # pinned / held software: only shown when a bump is available. age and
    # minisign are pinned binaries; wazuh-agent is apt-held on every VM and
    # upgraded by hand (manager first, then the agents).
    upd = []
    if data.get("age_update"):
        upd.append(f"age → {data['age_update']}")
    if data.get("minisign_update"):
        upd.append(f"minisign → {data['minisign_update']}")
    if data.get("wazuh_agent_update"):
        upd.append(f"wazuh-agent → {data['wazuh_agent_update']} (manager first, then all agents)")
    if upd:
        fields.append({"name": "🔧 Tool update available", "value": ", ".join(upd), "inline": False})

    title = f"{icon} Vault maintenance: {status.upper()}"
    if images_updated:
        title += " · images updated"
    return {
        "title": title,
        "color": color,
        "fields": fields,
        "footer": {"text": format_timestamp(ts)},
    }


# --- host maintenance: Pi-hole VM / wazuh-home / VPS (rules 100511/100512) -

MAINT_HOST_TITLES = {"pihole": "Pi-hole VM", "wazuh": "wazuh-home", "vps": "Edge VPS"}

def format_host_maintenance(alert):
    """
    Embed for the one-line nightly status a host's main.sh writes
    (event_type=host_maint). Same colours as the Vault VM's report; the @
    is decided by the caller (degraded/fail, or updated Pi-hole images).
    """
    data = alert.get("data", {})
    role = data.get("role", "")
    status = data.get("status", "unknown")
    images = data.get("images_updated", "")

    color = {"ok": 3066993, "degraded": 15844367, "fail": 15158332}.get(status, 10070709)
    icon = {"ok": "🟢", "degraded": "🟠", "fail": "🔴"}.get(status, "⚪")
    if status == "ok" and images:
        color, icon = 3447003, "🔵"    # clean run, new images went live

    fields = [
        {"name": "Host", "value": data.get("host") or "N/A", "inline": True},
        {"name": "Reboot", "value": data.get("reboot") or "N/A", "inline": True},
    ]
    if role == "pihole":
        fields.append({"name": "Containers", "value": data.get("containers") or "N/A", "inline": True})
        fields.append({"name": "Docker images updated",
                       "value": _maint_images(data), "inline": False})
    if data.get("geoip"):
        fields.append({"name": "GeoIP database", "value": data["geoip"], "inline": True})

    errors = data.get("errors", "")
    if errors:
        fields.append({"name": "⚠️ Problems",
                       "value": "\n".join(f"• {e}" for e in errors.split(";") if e)[:1024],
                       "inline": False})

    if "apt_count" in data:
        fields.append({"name": f"APT upgraded ({data.get('apt_count', '0')})",
                       "value": _maint_cap_list(data.get("apt_upgraded", "")), "inline": False})

    held = data.get("held_updates", "")
    if held:
        value = ", ".join(held.split(","))
        if "wazuh" in held:
            value += "\nUpgrade by hand with wazuh-home/UPGRADE.md: manager first, then the agents."
        fields.append({"name": "🔧 Held packages with an update", "value": value[:1024], "inline": False})

    title = f"{icon} {MAINT_HOST_TITLES.get(role, role or 'Host')} maintenance: {status.upper()}"
    if images:
        title += " · images updated"
    return {
        "title": title,
        "color": color,
        "fields": fields,
        "footer": {"text": format_timestamp(alert.get("timestamp", "N/A"))},
    }


# --- conffile: an upgrade kept a locally edited config file (rule 100601) ---

def format_conffile(alert):
    """
    Embed for dpkg's 'conffile <file> keep' decision: the nightly upgrade
    (force-confold) kept our edited file and saved the package's new
    version next to it as <file>.dpkg-dist. Nothing is broken; it's a
    nudge to look at what the new default changed.
    """
    data = alert.get("data", {})
    path = data.get("dpkg_conffile", "N/A")
    host = alert.get("agent", {}).get("name", "N/A")
    return {
        "title": "📝 Upgrade kept a local config file",
        "color": 3447003,
        "fields": [
            {"name": "Host", "value": host, "inline": True},
            {"name": "File", "value": f"`{path}`", "inline": True},
            {"name": "New default saved as", "value": f"`{path}.dpkg-dist`", "inline": False},
            {"name": "What to do",
             "value": f"Compare: `sudo diff {path} {path}.dpkg-dist`. Merge anything you "
                      "want into your file, then delete the `.dpkg-dist`.",
             "inline": False},
        ],
        "footer": {"text": format_timestamp(alert.get("timestamp", "N/A"))},
    }


# --- firewall: OPNsense blocked traffic to/from the Vault VM (100700/100701)

# One blocked TCP connect logs several lines (SYN retries) and a scan logs
# hundreds, so each src -> dst:port/proto posts once per FW_MUTE_SECONDS.
# The state file sits in a dir wazuh-integratord can write; any error with
# it fails open (the message is posted, just not deduplicated).
FW_SEEN_FILE = "/var/ossec/logs/custom-discord-fw-seen.json"
FW_MUTE_SECONDS = 180

def _fw_key(data):
    return (f"{data.get('srcip', '')}>{data.get('dstip', '')}:"
            f"{data.get('dstport', '')}/{data.get('protocol', '')}")

def _first_in_window(key, seen_file, mute_seconds):
    """True if `key` wasn't posted in the last mute_seconds; records it in
    seen_file. Shared by the firewall and modsec-FP mutes."""
    now = time.time()
    try:
        with open(seen_file, "a+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.seek(0)
            try:
                seen = json.load(f)
            except ValueError:
                seen = {}
            if not isinstance(seen, dict):
                seen = {}
            seen = {k: t for k, t in seen.items() if now - t < mute_seconds}
            if key in seen:
                return False
            seen[key] = now
            f.seek(0)
            f.truncate()
            json.dump(seen, f)
        return True
    except OSError:
        return True

def _fw_is_noise(ip):
    """Broadcast / multicast destinations (DHCP, mDNS, SSDP, ...): the
    default block rule logs them, but they're not a connection attempt."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.is_multicast or (a.version == 4 and str(a).endswith(".255"))

def _fw_is_out_of_state(full_log):
    """A TCP block that isn't a new connection (no SYN, or SYN+ACK): the
    tail of a connection the firewall already forgot, e.g. FIN/RST/ACK
    packets when containers are killed mid-connection. The default deny
    logs those, but nothing was actually refused. IPv4 filterlog CSV:
    field 9 = IP version, 17 = protocol, 24 = TCP flags."""
    try:
        f = full_log.split("]: ", 1)[1].split(",")
        if f[8] != "4" or f[16] != "tcp":
            return False
        flags = f[23]
    except (IndexError, AttributeError):
        return False
    return "S" not in flags or "A" in flags

def _filterlog_iface_dir(full_log):
    """Interface + direction from filterlog's CSV (fields 5 and 8), which
    the built-in pf decoder doesn't extract."""
    try:
        f = full_log.split("]: ", 1)[1].split(",")
        return f[4], f[7]
    except (IndexError, AttributeError):
        return "N/A", "N/A"

def format_firewall(alert):
    """
    Embed for an OPNsense block involving the Vault VM. 100700 = the VM
    tried to reach something its DMZ rules don't allow (e.g. the internet
    directly instead of through Squid); 100701 = something tried to reach
    the VM on a port nothing passes.
    """
    data = alert.get("data", {})
    rule_id = alert.get("rule", {}).get("id", "")
    src = data.get("srcip", "N/A")
    dst = data.get("dstip", "N/A")
    proto = data.get("protocol", "N/A")
    iface, direction = _filterlog_iface_dir(alert.get("full_log", ""))

    outbound = rule_id == "100700"
    remote = dst if outbound else src
    country, _ = resolve_geo(remote, {})
    title = ("🧱 Firewall blocked the Vault VM" if outbound
             else "🛡️ Firewall blocked traffic to the Vault VM")

    return {
        "title": title,
        "color": 15844367,  # amber
        "fields": [
            {"name": "From", "value": f"`{src}:{data.get('srcport', '?')}`", "inline": True},
            {"name": "To", "value": f"`{dst}:{data.get('dstport', '?')}`", "inline": True},
            {"name": "Protocol", "value": proto, "inline": True},
            {"name": "Remote side", "value": country, "inline": True},
            {"name": "Interface", "value": f"{iface} ({direction})", "inline": True},
            {"name": "Repeats", "value": f"same connection muted for {FW_MUTE_SECONDS // 60} min",
             "inline": True},
        ],
        "footer": {"text": format_timestamp(alert.get("timestamp", "N/A"))},
    }


# --- DORMANT templates for future sources. Not wired in main() yet; add a
#     WEBHOOKS key + an <integration> block + un-comment the branch, and
#     verify the real alert shape first (the way modsec was). ---

def format_fail2ban(alert):
    data = alert.get("data", {})
    rule = alert.get("rule", {})
    timestamp = alert.get("timestamp", "N/A")
    src_ip = data.get("srcip", "N/A")
    country_display, _ = resolve_geo(src_ip, alert.get("GeoLocation", {}))
    return {
        "title": "🔒 Fail2ban ban",
        "color": 16744272,
        "fields": [
            {"name": "Banned IP", "value": src_ip,                "inline": True},
            {"name": "Country",   "value": country_display,       "inline": True},
            {"name": "Jail",      "value": data.get("jail", "N/A"), "inline": True},
            {"name": "Agent",     "value": alert.get("agent", {}).get("name", "N/A"), "inline": True},
            {"name": "Rule",      "value": rule.get("description", "N/A"), "inline": False},
        ],
        "footer": {"text": format_timestamp(timestamp)},
    }


# --- agents: a Wazuh agent went quiet (rule 504) -----------------------------

def format_agent_down(alert):
    """
    Embed for rule 504: the manager hasn't heard from this agent for
    agents_disconnection_time (15 min). A normal reboot comes back well
    within that (506 stopped + 503 started, neither is posted), so this
    means the VM is down, hung, or cut off from the manager.
    """
    agent = alert.get("agent", {})
    return {
        "title": "🔴 Wazuh agent disconnected",
        "color": 15158332,  # red
        "fields": [
            {"name": "Agent",    "value": agent.get("name", "N/A"), "inline": True},
            {"name": "ID",       "value": agent.get("id", "N/A"),   "inline": True},
            {"name": "IP",       "value": agent.get("ip", "N/A"),   "inline": True},
            {"name": "Meaning",
             "value": "No contact for 15 min: VM down or hung, agent stopped, or network / "
                      "firewall cutting it off from wazuh-home. Its logs aren't reaching Wazuh.",
             "inline": False},
            {"name": "Check",
             "value": "Is the VM up in Proxmox? Then on it: `systemctl status wazuh-agent` and "
                      "`tail /var/ossec/logs/ossec.log`.",
             "inline": False},
        ],
        "footer": {"text": format_timestamp(alert.get("timestamp", "N/A"))},
    }


# ---------------------------------------------------------------------------
# Discord sender
# ---------------------------------------------------------------------------

def send_discord(webhook_url, embed, mention=None, retries=3, delay=5):
    payload = {"embeds": [embed]}
    if mention:
        payload["content"] = mention
    body = json.dumps(payload).encode("utf-8")
    # Discord's API is Cloudflare-fronted and 403s the default
    # "Python-urllib/x.y" User-Agent as a bot. Discord documents the UA
    # format as "DiscordBot ($url, $version)"; any descriptive UA clears it.
    req = urllib.request.Request(
        webhook_url, data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "DiscordBot (https://github.com/DiogoF-Hub/Homelab, 1.0)",
        },
        method="POST",
    )
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
            return
        except Exception:
            if attempt < retries - 1:
                time.sleep(delay)
            else:
                raise


def dashboard_link(alert):
    """
    Discover link to exactly this alert: a search on its Wazuh alert `id`
    (always indexed; our own data.* fields aren't searchable), in a fixed
    window of an hour either side of it, so the link still works weeks
    later. Same URL shape the dashboard itself produces. "" if there's no
    dashboard_url, or the alert has no usable id or timestamp.
    """
    alert_id = str(alert.get("id") or "")
    host = DASHBOARD_URL.split("://", 1)[-1].split("/", 1)[0]
    if "." not in host or "REPLACE_WITH" in host or not alert_id.replace(".", "").isdigit():
        return ""       # no dot: Discord would reject the whole message
    try:
        t = datetime.strptime(alert.get("timestamp", ""), "%Y-%m-%dT%H:%M:%S.%f%z")
    except ValueError:
        return ""
    t = t.astimezone(timezone.utc)
    span = lambda d: (t + d).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    query = quote(f'id:"{alert_id}"', safe=":")
    return (f"{DASHBOARD_URL}/app/data-explorer/discover#?"
            "_a=(discover:(columns:!(_source),isDirty:!f,sort:!()),"
            "metadata:(indexPattern:'wazuh-alerts-*',view:discover))"
            "&_g=(filters:!(),refreshInterval:(pause:!t,value:0),"
            f"time:(from:'{span(timedelta(hours=-1))}',to:'{span(timedelta(hours=1))}'))"
            f"&_q=(filters:!(),query:(language:kuery,query:'{query}'))")


def deliver(channel, embed, mention=MENTION):
    """
    Post to the channel's webhook. Skips silently if that channel's URL is
    still a placeholder, so a freshly-deployed (un-filled) manager stays
    quiet instead of erroring. `mention` defaults to the global MENTION;
    pass "" to post without a ping (e.g. the all-OK maintenance heartbeat).
    """
    url = WEBHOOKS.get(channel, "")
    if not url or "REPLACE_WITH" in url:
        return
    if ALERT_URL and "url" not in embed:
        embed["url"] = ALERT_URL       # makes the title a link to the alert
    try:
        send_discord(url, embed, mention=(mention or None))
    except urllib.error.HTTPError as e:
        # Discord answers 400 to an embed it doesn't like; if the link is
        # the cause, the alert still goes out, just without it.
        if e.code == 400 and embed.pop("url", None):
            send_discord(url, embed, mention=(mention or None))
        else:
            raise


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    # Wazuh calls: custom-discord <alert_file> <api_key> <hook_url> [opts].
    # We only need the alert file; the webhook comes from WEBHOOKS, not argv.
    if len(sys.argv) < 2:
        sys.exit(1)

    with open(sys.argv[1]) as f:
        alert = json.load(f)

    global ALERT_URL
    ALERT_URL = dashboard_link(alert)

    data = alert.get("data", {})
    rule = alert.get("rule", {})
    groups = rule.get("groups", [])
    level = int(rule.get("level", 0))
    location = alert.get("location", "")

    # --- modsec: band=high attacks (rule 100303, level 11) and flagged
    #     responses (rule 100304, level 12). Only a flagged response gets
    #     the @: a band=high attack was already blocked (engine On), and
    #     CrowdSec bans anything scoring 10+, so there's nothing to do but
    #     read it. A flagged response is a possible leak, or a false
    #     positive breaking a real client: look now.
    #     Rule 100305 (a real Bitwarden client blocked) always gets the @,
    #     muted per src + request + rules for an hour. ---
    if "modsecurity" in groups:
        if str(rule.get("id")) == "100305":
            if _first_in_window(_modsec_fp_key(data), MODSEC_FP_SEEN_FILE, MODSEC_FP_MUTE_SECONDS):
                deliver("modsec", format_modsecurity(alert))
        elif data.get("band") == "high" or level >= 11:
            flagged = str(data.get("outbound_score") or "0") not in ("", "0")
            deliver("modsec", format_modsecurity(alert),
                    mention=(MENTION if flagged else ""))

    # --- dns: only Pi-hole allowlist denials (status=blocked-regex), i.e.
    #     the Vault VM tried to resolve a domain that isn't on its allowlist.
    #     Resolved queries and upstream non-answers (NXDOMAIN / null /
    #     Cloudflare Family filtering) never ping. ---
    elif "pihole" in groups or "vault-dns/events.log" in location:
        if data.get("status") == "blocked-regex":
            deliver("dns", format_dns(alert))

    # --- squid: egress-allowlist denials only ---
    elif "squid" in groups or "squid/access.log" in location:
        if data.get("action") == "TCP_DENIED":
            deliver("squid", format_squid(alert))

    # --- fail2ban: a host was banned. Rule 100401 (custom fail2ban-file
    #     decoder) already filters to f2b_action=Ban, so key on the rule. ---
    elif rule.get("id") == "100401":
        deliver("fail2ban", format_fail2ban(alert))

    # --- firewall: OPNsense blocks to/from the Vault VM (100700 / 100701),
    #     minus broadcast/multicast and out-of-state TCP leftovers, once
    #     per connection per 3 min. ---
    elif rule.get("id") in ("100700", "100701"):
        if (not _fw_is_noise(data.get("dstip", ""))
                and not _fw_is_out_of_state(alert.get("full_log", ""))
                and _first_in_window(_fw_key(data), FW_SEEN_FILE, FW_MUTE_SECONDS)):
            deliver("firewall", format_firewall(alert))

    # --- maintenance: nightly run summary. 100501 = ok (quiet heartbeat),
    #     100502 = degraded|fail. @ you when it's not ok, and also when a
    #     container image was updated: a new release goes live at the reboot
    #     that follows, which is when something is most likely to break. ---
    elif rule.get("id") in ("100501", "100502"):
        ping = data.get("status") != "ok" or images_were_updated(alert)
        deliver("maintenance", format_maintenance(alert),
                mention=(MENTION if ping else ""))

    # --- host maintenance: nightly report of the Pi-hole VM, wazuh-home
    #     and the VPS, to the #maintenance of the host's Discord category
    #     (falls back to the Vault VM's #maintenance while that webhook
    #     isn't configured). @ on degraded/fail and when Pi-hole images
    #     were updated, like the Vault VM's report. ---
    elif rule.get("id") in ("100511", "100512"):
        channel = f"maintenance-{data.get('role', '')}"
        if "REPLACE_WITH" in WEBHOOKS.get(channel, "REPLACE_WITH"):
            channel = "maintenance"
        ping = data.get("status") != "ok" or bool(data.get("images_updated"))
        deliver(channel, format_host_maintenance(alert),
                mention=(MENTION if ping else ""))

    # --- conffile: an upgrade kept a locally edited config file (any
    #     agent). Own channel with an @, it wants a look; falls back to
    #     #maintenance while no "conffile" webhook is configured. ---
    elif rule.get("id") == "100601":
        channel = "conffile"
        if "REPLACE_WITH" in WEBHOOKS.get(channel, "REPLACE_WITH"):
            channel = "maintenance"
        deliver(channel, format_conffile(alert))

    # --- agents: no contact for agents_disconnection_time (rule 504). The
    #     nightly reboots' clean stop/start (506/503) are deliberately not
    #     posted, they'd ping every night for nothing. ---
    elif rule.get("id") == "504":
        deliver("agents", format_agent_down(alert))


if __name__ == "__main__":
    main()
