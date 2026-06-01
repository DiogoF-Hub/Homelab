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
             Pings on band=high only (rule 100303, level 11), the
             multi-vector attacks, never the scanner noise.
  - dns    : Pi-hole FTL events from the Vault VM (manager-rules.xml).
             Pings on blocked=true EXCEPT status=blocked-external-null-reply
             (upstream NULL-reply noise), matching the dashboard filter.
  - squid  : Squid access log on proxy-home (Wazuh built-in squid
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
first, the way modsec was): fail2ban bans, Wazuh agent-down (504/506).
CrowdSec is a bigger lift, it doesn't ship to Wazuh in this stack at all
(feeds the BunkerWeb plugin + VPS firewall bouncer), so that's a whole
separate pipeline, not just a formatter.

stdlib only (urllib, json, datetime, zoneinfo), no pip, no requests.
"""

import sys
import json
import time
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

# Optional Discord mention prepended to every notification (a role or
# user id like "<@&123...>" / "<@123...>"). Empty = no ping.
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
}
try:
    with open("/var/ossec/integrations/discord-webhooks.json") as _wf:
        WEBHOOKS.update(json.load(_wf))
except (FileNotFoundError, ValueError, OSError):
    pass    # no side-file (or unreadable) -> placeholders stay; deliver() skips them


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


def geoip_lookup(ip):
    """
    Best-effort country/city from ip-api.com (free tier, HTTP only).
    Requires manager egress to ip-api.com:80. Fails soft to {} so the
    embed just omits geo if there's no egress or the lookup errors.
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
    present, else an ip-api fallback, else a private/unknown label.
    """
    country = geo.get("country_name", "")
    country_code = geo.get("country_code2", "")
    city = geo.get("city_name", "")
    region = geo.get("region_name", "")

    if not country and src_ip not in ("N/A", "") and not is_private_ip(src_ip):
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


# ---------------------------------------------------------------------------
# Embed formatters (one per wired source)
# ---------------------------------------------------------------------------

def format_modsecurity(alert):
    """
    Discord embed from a flattened modsec event (rule 100303, band=high).
    Reads the clean fields the sidecar emits; no full_log scraping.
    """
    data = alert.get("data", {})
    geo = alert.get("GeoLocation", {})
    agent = alert.get("agent", {})

    src_ip = data.get("srcip", "N/A")
    method = data.get("method", "N/A")
    path = data.get("path", "N/A")
    score = data.get("anomaly_score", "N/A")
    rule_ids = data.get("rule_ids", "N/A")
    engine = data.get("engine", "N/A")
    http_code = data.get("http_code", "N/A")
    agent_name = agent.get("name", "N/A")
    timestamp = alert.get("timestamp", "N/A")

    country_display, location = resolve_geo(src_ip, geo)

    # In DetectionOnly the score is what modsec WOULD block; in On it's
    # what it DID block. Make that explicit.
    if engine == "On":
        enforced = "On (blocked)"
    elif engine == "DetectionOnly":
        enforced = "DetectionOnly (would block)"
    else:
        enforced = str(engine)

    return {
        "title": "🚨 ModSecurity , high-severity attack",
        "color": 15158332,  # red
        "fields": [
            {"name": "Agent",         "value": agent_name,           "inline": True},
            {"name": "Source IP",     "value": src_ip,               "inline": True},
            {"name": "Country",       "value": country_display,      "inline": True},
            {"name": "Location",      "value": location,             "inline": True},
            {"name": "HTTP code",     "value": str(http_code),       "inline": True},
            {"name": "Anomaly score", "value": str(score),           "inline": True},
            {"name": "Request",       "value": f"`{method} {path}`", "inline": False},
            {"name": "CRS rules",     "value": f"`{rule_ids}`",      "inline": False},
            {"name": "Engine",        "value": enforced,             "inline": False},
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

def format_maintenance(alert):
    """
    Discord embed from the nightly `run` summary event. main.sh rolls the
    per-phase status lines into one event with these data.* fields. Color +
    icon track the overall status; the @ is decided by the caller (only on
    degraded/fail), not here.
    """
    data = alert.get("data", {})
    ts = alert.get("timestamp", "N/A")
    status = data.get("status", "unknown")

    color = {"ok": 3066993, "degraded": 15844367, "fail": 15158332}.get(status, 10070709)
    icon = {"ok": "🟢", "degraded": "🟠", "fail": "🔴"}.get(status, "⚪")

    backup = data.get("backup_status", "N/A")
    size = data.get("backup_size", "")
    backup_val = f"{backup} ({size})" if size else backup
    images = data.get("images_updated", "")

    fields = [
        {"name": "Backup", "value": backup_val, "inline": True},
        {"name": "Reboot", "value": data.get("reboot_status") or "scheduled", "inline": True},
        {"name": "Docker images updated", "value": (images.replace(",", ", ") if images else "none"), "inline": False},
    ]

    pulls = data.get("pull_failures", "")
    if pulls:
        fields.append({"name": "⚠️ Docker pull FAILED", "value": pulls.replace(",", ", "), "inline": False})

    fields.append({
        "name": f"APT upgraded ({data.get('apt_count', '0')})",
        "value": _maint_cap_list(data.get("apt_upgraded", "")),
        "inline": False,
    })

    # the two pinned tools (age / minisign): only shown when a bump is available
    upd = []
    if data.get("age_update"):
        upd.append(f"age → {data['age_update']}")
    if data.get("minisign_update"):
        upd.append(f"minisign → {data['minisign_update']}")
    if upd:
        fields.append({"name": "🔧 Tool update available", "value": ", ".join(upd), "inline": False})

    return {
        "title": f"{icon} Vault maintenance: {status.upper()}",
        "color": color,
        "fields": fields,
        "footer": {"text": format_timestamp(ts)},
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


def format_agent_down(alert):
    agent = alert.get("agent", {})
    rule = alert.get("rule", {})
    timestamp = alert.get("timestamp", "N/A")
    return {
        "title": "🔴 Wazuh agent down",
        "color": 15158332,
        "fields": [
            {"name": "Agent name", "value": agent.get("name", "N/A"), "inline": True},
            {"name": "Agent ID",   "value": agent.get("id", "N/A"),   "inline": True},
            {"name": "Agent IP",   "value": agent.get("ip", "N/A"),   "inline": True},
            {"name": "Event",      "value": f"{rule.get('id','N/A')} - {rule.get('description','N/A')}", "inline": False},
        ],
        "footer": {"text": format_timestamp(timestamp)},
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
    send_discord(url, embed, mention=(mention or None))


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

    data = alert.get("data", {})
    rule = alert.get("rule", {})
    groups = rule.get("groups", [])
    level = int(rule.get("level", 0))
    location = alert.get("location", "")

    # --- modsec: band=high attacks only (rule 100303, level 11) ---
    if "modsecurity" in groups:
        if data.get("band") == "high" or level >= 11:
            deliver("modsec", format_modsecurity(alert))

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

    # --- maintenance: nightly run summary. 100501 = ok (quiet heartbeat),
    #     100502 = degraded|fail. @ you only when it's not ok. ---
    elif rule.get("id") in ("100501", "100502"):
        deliver("maintenance", format_maintenance(alert),
                mention=(MENTION if data.get("status") != "ok" else ""))

    # --- FUTURE (add WEBHOOKS key + <integration> block, verify shape) ---
    # elif rule.get("id", "") in ("504", "506"):
    #     deliver("agent", format_agent_down(alert))


if __name__ == "__main__":
    main()
