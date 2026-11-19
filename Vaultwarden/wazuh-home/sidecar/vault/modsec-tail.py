#!/usr/bin/env python3
"""
modsec-tail.py: BunkerWeb ModSecurity JSON audit log -> Wazuh log shipper.

Tails BunkerWeb's modsec_audit.log (JSON audit format, one transaction
object per line), flattens each transaction into a single flat JSON
line with clean scalar fields, and appends it to
/var/log/modsec-events/events.log. The Wazuh agent on this VM tails
that file via a <localfile> entry; the manager fires rules
100300 / 100301 / 100302 / 100303 / 100304 / 100305 (see
Vaultwarden/wazuh-home/modsec/manager-modsec-rules.xml) on the decoded events.

It also tails BunkerWeb's error.log for the "[ACCESS] denied access from
<plugin> : <reason>" lines its plugins (dnsbl, crowdsec, country, rdns,
useragent, limit, ...) write when they deny a request. Two uses:
  - each one becomes its own `bw_deny` event (rules 100320 / 100321),
    so denials of requests that never tripped a CRS rule show up too
  - a modsec event whose request was denied by a plugin gets
    `denied_by` / `deny_reason`, so a 403 with blocked=no reads as
    "CRS scored it, dnsbl blocked it" instead of an unexplained 403

And it names attacks it has seen before (known_attack / known_cve), from
the table in /etc/modsec-tail/known-attacks.json. custom-discord pings for
any modsec event (any score) that ISN'T in that table, so Discord carries just
the new ones; adding an entry is how one goes quiet. See KnownAttacks.

WHY THIS EXISTS (why not tail modsec_audit.log directly)

Wazuh's built-in JSON decoder flattens nested *objects* into dotted
data.* fields cleanly, but it collapses an array-of-objects into one
opaque string. ModSecurity's audit record carries everything that
matters (which CRS rules matched, their severities, the anomaly score)
inside transaction.messages[], an array. Pointed at the raw log, Wazuh
hands you transaction.messages as a single stringified blob you cannot
filter on per-rule. Verified on Wazuh 4.14 with wazuh-logtest.

Worse, the obvious "was it blocked" signal is misleading. In this
stack http_code does NOT track severity: the heaviest multi-vector
RCE/SQLi probes hit POST / (a path that doesn't exist) and come back
404, while a harmless missing-User-Agent scan of a WordPress path
comes back 403. Tiering on http_code would be backwards.

The clean severity signal is the CRS anomaly score, reported by rule
949110 ("Inbound Anomaly Score Exceeded (Total Score: N)"). Observed
scores cluster: 5-10 for routine file/secret scanning (.env, .git),
30-55 for real multi-vector attacks, with a wide gap between. This
script parses each transaction once, pulls out the score and the rule
list, and emits flat fields so the manager rules tier on a clean
`band` value instead of regex-diving a stringified array.

EVERYTHING ELSE RIDES ALONG TOO

Besides the tiering fields, each event carries the rest of the record
so the dashboard can filter on it and an event can be read on its own:
the full URI + query, every request header (as one string, plus the
common ones as their own fields), the request body, the response
headers, per-rule severity / paranoia level / CAPEC / matched data, the
ModSecurity + CRS versions, and `raw`, the whole transaction as one
JSON string. Nothing is redacted: Wazuh is a trusted store here, by
decision (2026-11). Discord never sees any of it, custom-discord.py
reads named fields only.

Headers go in as one `Name: value` string, never as JSON keys: header
names are attacker-chosen, and one indexed field per name would blow the
indexer's field limit over time.

Size limits (the reason for the caps below): Wazuh truncates an event
line at ~64 KB, which breaks the JSON and loses the event, and the
indexer refuses a whole document if one keyword field is over 32766
bytes. So every string is capped, and if a line still doesn't fit the
big fields are shrunk in order (raw first, then the body, ...) until it
does. The tiering fields are never touched.

`lookup` / `lookup_safe` are ready-to-paste shell commands (run on this
VM) that print this request's lines from modsec_audit.log, error.log and
access.log, pretty-printed. `lookup_safe` is the same with IPs masked,
query strings stripped, auth / cookie headers, bodies and matched data
hidden: for pasting the output somewhere. They only work while the logs
still exist (BunkerWeb rotates bw-logs daily, keeps 14). Every value spliced into them
is checked against a strict pattern first, so an odd value can never
turn into shell syntax.

ARCHITECTURE

  Vault VM                                   wazuh-home (manager)
  --------                                   -------------------
  bunkerweb container (rootless podman)
    ModSecurity writes /var/log/bunkerweb/modsec_audit.log
    nginx / plugins write /var/log/bunkerweb/error.log
                                ^
                                | bind mount to host /srv/bw-logs
                                |
  modsec-tail.py (this script)
    poll both logs every TICK seconds from saved byte offsets
    -> flatten each transaction / denial -> append JSON line to
       /var/log/modsec-events/events.log
                                ^
                                | tailed by Wazuh agent
                                |
  wazuh-agent
    ships event over encrypted channel to wazuh-home
                                ^
                                v
                                rules fire:
                                100300 (level 0):  every modsec event, archived
                                100301 (level 3):  band=none  (probe / redirect noise)
                                100302 (level 7):  band=low|mid (routine scoring scans)
                                100303 (level 11): band=high (real multi-vector attack)
                                100304 (level 12): outbound_score > 0 (response flagged)
                                100305 (level 12): blocked=yes + a Bitwarden client name
                                                   (a real client got blocked: likely FP)
                                100320 (level 0):  every bw_deny event, archived
                                100321 (level 3):  a BunkerWeb plugin denied a request

MATCHING A DENIAL TO ITS AUDIT RECORD

The "[ACCESS] denied" line doesn't carry ModSecurity's unique_id, so the
match is on client IP + method + URI, within DENY_MATCH_SECONDS of the
audit record's timestamp, closest first, each denial used once. The
denial is written in nginx's access phase, the audit record at the end
of the request, so reading the audit log BEFORE error.log in each tick
guarantees the denial of any audit record we just read is already in
what we read from error.log. nginx caps an error.log line at 2 KB, so a
long URI can be cut off: a cut request line matches as a prefix.

STATE

  Byte offset into each log persisted in its own state file so the
  daemon resumes exactly where it left off across restarts: no dropped
  events, no replays. On first run (no state file) a log starts at its
  current end, skipping the historical backlog. Rotation via
  copytruncate is detected by the file shrinking below our offset; a
  rotate-rename is detected by the inode changing.

CONFIG

  Edit the constants below for your environment. Defaults match the
  reference setup documented in Vaultwarden/wazuh-home/README.md.

SAFETY

  Reads the logs (attacker-controlled, byte-dirty payloads) only via
  json.loads and regexes, which treat every field as an inert string.
  The script never shells out (no subprocess / os.system / eval), so a
  payload can never escape into a command context. stdlib only.
"""

import ipaddress
import json
import re
import signal
import sys
import time
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

AUDIT_LOG = Path("/srv/bw-logs/modsec_audit.log")
"""
BunkerWeb's ModSecurity JSON audit log on the host. The bunkerweb
container bind-mounts /var/log/bunkerweb from /srv/bw-logs; if your
mount differs, adjust here. Must be JSON format (SecAuditLogFormat
JSON, set in bunkerweb/custom-configs/modsec/audit-log-format.conf).
"""

ERROR_LOG = AUDIT_LOG.parent / "error.log"
"""
BunkerWeb's nginx error log, same bind mount. Only its "[ACCESS] denied
access from" lines are used. If it's unreadable the modsec events still
flow, just without denied_by and without bw_deny events (logged once).
"""

ACCESS_LOG = AUDIT_LOG.parent / "access.log"
"""Never read by this script; only named in the lookup commands."""

OUTPUT_LOG = Path("/var/log/modsec-events/events.log")
"""
Where this script appends flat JSON-per-line events. The Wazuh agent
on this VM tails this file; see
Vaultwarden/wazuh-home/modsec/vault-modsec-agent.localfile.xml.

Own subdirectory so logrotate can target the dir cleanly. Rotation
config deployed by hand to /etc/logrotate.d/modsec-events; canonical
text in Vaultwarden/README.md. Daily, keep 14, compress, copytruncate.
Opened in append mode so copytruncate keeps our writes landing at EOF.
"""

STATE_FILE = Path("/var/lib/modsec-tail/offset")
"""
Persists the last processed byte offset into the audit log across
restarts. Atomic write via a `.tmp` rename so a crash mid-write can't
truncate it to zero.
"""

ERROR_STATE_FILE = Path("/var/lib/modsec-tail/errorlog-offset")
"""Same, for error.log."""

KNOWN_ATTACKS_FILE = Path("/etc/modsec-tail/known-attacks.json")
"""
The table of attacks we've already seen and named (React2Shell, the
Next.js middleware bypass, secret-file scans, ...). Each modsec event that
matches an entry gets known_attack / known_cve. custom-discord pings for any
modsec event whose known_attack is EMPTY, i.e. something new: adding an
entry here is how a new attack goes quiet. Re-read whenever the file
changes, no restart needed. Missing or broken file -> no names, logged
once; a broken edit keeps the previous table. Format: see the file's own
_readme (repo: wazuh-home/sidecar/vault/known-attacks.json).
"""

TICK_SECONDS = 2
"""
Polling interval. The audit log only grows on a CRS match (RelevantOnly)
and stays small, so a tight 2s tick is cheap and keeps Discord latency
low. The loop wakes every 0.1s to stay responsive to SIGTERM.
"""

MAX_READ_BYTES = 8 * 1024 * 1024
"""
Cap on bytes pulled per read. Bounds catch-up cost / memory after a
long downtime. The next read continues from the advanced offset.
"""

MAX_ERROR_READS = 16
"""
error.log reads per tick. It's read until caught up (the denial match
needs everything up to now), bounded so a huge backlog after downtime
can't stall the tick.
"""

EVENT_TYPE = "bw_modsec"
"""
Discriminator embedded in every event so manager rules scope to "events
from this script" via <field name="event_type">bw_modsec</field>,
independent of the location path. Keep stable; rules match on it.
"""

DENY_EVENT_TYPE = "bw_deny"
"""Same, for the plugin-denial events (rules 100320 / 100321)."""

DENY_MATCH_SECONDS = 5
"""Max gap between a denial and the audit record it's matched to."""

DENY_KEEP_SECONDS = 120
"""How long an unmatched denial stays matchable."""

KNOWN_FIELDS = ("method", "path", "query", "uri", "body", "body_raw", "host",
                "ua", "headers", "header_names", "rules", "attacks")
"""
What a known-attacks.json condition can look at ("in"), besides
"header:<name>" (one request header, case-insensitive). body is the request
body with \\uXXXX / \\xNN escapes undone (attackers write "__proto__" as
"\\u005f\\u005f\\u0070..." to dodge substring filters), body_raw the body as
sent. headers is every header as "name: value" lines, header_names the
comma-joined names in the order sent, rules / attacks the comma-joined rule
ids / CRS attack types.
"""

_ESCAPE_RE = re.compile(r"\\u([0-9a-fA-F]{4})|\\x([0-9a-fA-F]{2})")

def deobfuscate(text):
    """Undo \\uXXXX and \\xNN escapes written out as text, for matching only
    (never shipped). Covers both ModSecurity's \\xNN for raw bytes and the
    attacker's own escaping."""
    return _ESCAPE_RE.sub(lambda m: chr(int(m.group(1) or m.group(2), 16)), text)

# CRS anomaly-score band thresholds. Tier boundaries the manager rules
# key on via the `band` field. Picked from observed data: routine
# secret-file scanning scores 5-10, real multi-vector attacks score
# 30-55, with a clean gap. Retune here if your traffic differs.
SCORE_MID_MIN = 10    # score >= this -> "mid"
SCORE_HIGH_MIN = 30   # score >= this -> "high" (the Discord tier)

# Size caps, in UTF-8 bytes. FIELD_MAX stays under the indexer's 32766-byte
# keyword limit; LINE_MAX under Wazuh's ~64 KB event line.
LINE_MAX = 60000
FIELD_MAX = 30000
BODY_MAX = 16000
BLOCK_MAX = 8000      # req_headers, resp_headers, matches, matched_data, rule_msgs
URI_MAX = 4000
VALUE_MAX = 1024      # single header values, deny_reason

# If a line is still over LINE_MAX, shrink these in order until it fits
# (0 = drop, leaving a note with the original size).
SHRINK_STEPS = (
    ("raw", 0),
    ("req_body", 2000),
    ("req_headers", 2000),
    ("resp_headers", 2000),
    ("matches", 2000),
    ("matched_data", 2000),
    ("rule_msgs", 2000),
    ("req_body", 0),
)

# 949110's message reads "Inbound Anomaly Score Exceeded (Total Score: N)".
SCORE_RE = re.compile(r"Total Score:\s*(\d+)")

# A rule's details.data reads "Matched Data: <text> found within <VAR>: <value>".
# matched_in keeps just <VAR> (ARGS:path, REQUEST_URI_RAW, ...), the short
# filterable version; the full text is in matched_data.
WHERE_RE = re.compile(r"found within ([A-Z_]+(?::[^:\s]{1,64})?):")

# Rules that only score or correlate, not detect: left out of rule_msgs,
# severities and paranoia_levels (949110 is tagged CRITICAL itself).
NON_DETECTION_RULES = ("949", "959", "980")
MAX_WHERE = 10

# Rules whose firing IS the block with the engine On: 949110 (inbound score
# over threshold -> 403), 959100 (outbound score -> response blocked),
# 200002 (request body failed to parse -> 400). Everything else only adds
# to a score, so a lone PL2 match on a request that went through doesn't
# count as blocked.
VERDICT_RULES = ("949110", "959100", "200002")

# Request headers that also get their own field, case-insensitive. Bitwarden
# clients send Bitwarden-Client-Name (web / browser / desktop / mobile /
# cli) and -Version on every API call; scanners don't. That's what lets
# rule 100305 single out a blocked REAL client (a likely false positive).
# The rest are for filtering (accept_encoding=identity, no accept_language,
# ... tell a script from a browser). Every header is in req_headers anyway.
HEADER_FIELDS = {
    "client_name":     "bitwarden-client-name",
    "client_version":  "bitwarden-client-version",
    "user_agent":      "user-agent",
    "accept":          "accept",
    "accept_encoding": "accept-encoding",
    "accept_language": "accept-language",
    "referer":         "referer",
    "origin":          "origin",
    "content_type":    "content-type",
    "content_length":  "content-length",
    "connection":      "connection",
}

# ModSecurity's numeric severities, most severe first.
SEVERITY_NAMES = {
    "0": "EMERGENCY", "1": "ALERT", "2": "CRITICAL", "3": "ERROR",
    "4": "WARNING", "5": "NOTICE", "6": "INFO", "7": "DEBUG",
}

# BunkerWeb's listeners inside the container.
LISTENERS = {"8443": "https", "8080": "http"}

MONTH_NAMES = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

# Audit time_stamp is ctime-style: "Tue Nov 10 11:38:42 2026" (day space-padded).
AUDIT_TS_RE = re.compile(r"^\w{3} (\w{3}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$")

# error.log: "2026/11/10 11:38:42 [warn] 1584#1584: *10256 <message>"
ERR_HEAD_RE = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(\w+)\] (\d+#\d+): \*(\d+) (.*)$")
# "<message>" = "[ACCESS] denied access from dnsbl : IP is blacklisted by ..., client: ..."
DENY_RE = re.compile(r"^\[([A-Z_]+)\] denied access from (\S+) : (.*)$")
# nginx's own context suffix. The LAST match wins: the reason text comes
# first and could contain the same words.
CTX_RE = re.compile(r', client: ([^,\s]+), server: ([^,]*), request: "')
REQ_RE = re.compile(r'^(.*?)"(?=, (?:upstream|host|referrer): |$)')
HOST_RE = re.compile(r', host: "([^"]*)"')
REF_RE = re.compile(r', referrer: "([^"]*)"')

# What may be spliced into a lookup command. Anything else -> left out.
UID_OK = re.compile(r"^[0-9]+\.[0-9]+$")
CONN_OK = re.compile(r"^[0-9]+#[0-9]+: \*[0-9]+$")

# ---------------------------------------------------------------------
# Lookup command pieces (shell text, single-quoted where used: none of
# these may contain a single quote)
# ---------------------------------------------------------------------

AUDIT_GLOB = AUDIT_LOG.as_posix() + "*"
ERROR_GLOB = ERROR_LOG.as_posix() + "*"
ACCESS_GLOB = ACCESS_LOG.as_posix() + "*"

# sed -E. One modsec "[field ...]" per line, the plugin's "[ACCESS] denied"
# and nginx's "client: ..., server: ..." each on their own line, and a blank
# line after each log line.
SED_PRETTY = (r's/ \[(file|line|id|rev|msg|data|severity|ver|maturity|accuracy|tag|hostname|uri|unique_id|ref) "/\n    [\1 "/g; '
              r's/ \[([A-Z_]+)\] denied /\n    [\1] denied /; '
              r's/, client: ([^,]*), server: /\n    client: \1, server: /; '
              r's/$/\n/')
# sed -E. IPv4 -> a.b.c.x (not version numbers like Chrome/147.0.0.0),
# IPv6 -> first 4 groups + x, query strings stripped.
SED_MASK = (r's/(^|[^0-9./])([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.[0-9]{1,3}([^0-9.]|$)/\1\2.x\3/g; '
            r's/(([0-9a-fA-F]{1,4}:){4})[0-9a-fA-F:]+/\1x/g; '
            r's/\?[^" ]*//g')
# The matched text in a modsec warning line: [data "..."] and (Value: ...).
SED_HIDE = (r's/\[data ".*"\] \[severity/[data "<hidden>"] [severity/; '
            r's/\(Value: .*\) \[file "/(Value: <hidden>) [file "/')
JQ_SAFE = " | ".join((
    r'.transaction',
    r'.client_ip |= (if test(":") then (split(":") | .[:4] | join(":")) + "::x" else sub("\\.[0-9]+$"; ".x") end)',
    r'.request.uri |= sub("\\?.*"; "?<query stripped>")',
    r'.request.headers |= ((. // {}) | with_entries(if (.key | ascii_downcase | test("^(authorization|cookie|proxy-authorization)$")) then .value = "<redacted>" elif (.key | ascii_downcase) == "referer" then .value |= sub("\\?.*"; "?<query stripped>") else . end))',
    r'.response.headers |= ((. // {}) | with_entries(if (.key | ascii_downcase) == "set-cookie" then .value = "<redacted>" else . end))',
    r'.request.body |= "<\(length) chars>"',
    r'.messages |= ((. // []) | map(.details |= ((.data |= (if (. // "") != "" then "<matched data hidden>" else . end)) | (.match |= (if . then sub("\\(Value: .*"; "(Value: <hidden>)") else . end)))))',
))

# ---------------------------------------------------------------------
# Shutdown flag
# ---------------------------------------------------------------------

_STOP = False

def _handle_stop(signum, _frame):
    """SIGTERM/SIGINT -> finish the current tick and exit cleanly."""
    global _STOP
    _STOP = True

def log(msg):
    print(msg, file=sys.stderr, flush=True)

# ---------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------

def load_offset(state_file):
    """Return the saved byte offset, or None on first run."""
    try:
        return int(state_file.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None

def save_offset(state_file, value):
    """Atomically persist the byte offset (temp file + rename)."""
    state_file.parent.mkdir(parents=True, exist_ok=True)
    tmp = state_file.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(state_file)

# ---------------------------------------------------------------------
# Tailing
# ---------------------------------------------------------------------

class Tail:
    """Byte-offset tail of one log file, offset persisted in state_file."""

    def __init__(self, path, state_file):
        self.path = path
        self.state_file = state_file
        offset = load_offset(state_file)
        if offset is None:
            # First run: start at EOF so we don't replay the existing log.
            offset = path.stat().st_size if path.exists() else 0
            save_offset(state_file, offset)
            log(f"{path.name}: first run, starting at offset={offset}")
        self.offset = offset
        self.ino = path.stat().st_ino if path.exists() else None

    def read(self):
        """
        Complete new lines since the offset, as bytes. Handles rotation:
        copytruncate (file shrinks below our offset -> reset to 0) and
        rotate-rename (inode changes -> reset to 0). Leaves a trailing
        partial line (no newline yet) for the next read so we never parse
        half a record.
        """
        try:
            st = self.path.stat()
        except FileNotFoundError:
            # bunkerweb not up yet; nothing to do.
            return []

        offset = self.offset
        if self.ino != st.st_ino or st.st_size < offset:
            offset = 0
        self.ino = st.st_ino
        self.offset = offset
        if st.st_size == offset:
            return []

        with self.path.open("rb") as f:
            f.seek(offset)
            data = f.read(MAX_READ_BYTES)

        last_nl = data.rfind(b"\n")
        if last_nl == -1:
            if len(data) >= MAX_READ_BYTES:
                # one line longer than a whole read: skip it rather than
                # stall on it forever.
                log(f"{self.path.name}: skipping an over-long line at offset={offset}")
                self.offset = offset + len(data)
            return []

        complete = data[:last_nl + 1]
        self.offset = offset + len(complete)
        return [ln for ln in complete.split(b"\n") if ln.strip()]

    def save(self):
        save_offset(self.state_file, self.offset)

# ---------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------

def cap(value, limit):
    """Cut a string to `limit` UTF-8 bytes, noting how much was cut."""
    s = "" if value is None else str(value)
    b = s.encode("utf-8", "replace")
    if len(b) <= limit:
        return s
    return b[:limit].decode("utf-8", "ignore") + f" ...[+{len(b) - limit} bytes]"

def unique(items):
    """De-duplicate, keeping first-seen order."""
    return list(dict.fromkeys(i for i in items if i))

def norm_ip(value):
    """Canonical text form of an IP, or "" if it isn't one."""
    try:
        return str(ipaddress.ip_address(str(value).strip()))
    except ValueError:
        return ""

def split_uri(uri):
    path, _, query = (uri or "").partition("?")
    return path, query

def parse_audit_ts(value):
    found = AUDIT_TS_RE.match(value or "")
    if not found:
        return None
    mon, day, hh, mm, ss, year = found.groups()
    if mon not in MONTH_NAMES:
        return None
    try:
        return datetime(int(year), MONTH_NAMES.index(mon) + 1, int(day),
                        int(hh), int(mm), int(ss))
    except ValueError:
        return None

def headers_dict(value):
    return value if isinstance(value, dict) else {}

def headers_text(headers, skip_empty=False):
    """All headers as one "Name: value" string, one per line."""
    return "\n".join(f"{k}: {v}" for k, v in headers.items()
                     if not (skip_empty and v in ("", None)))

def header_get(headers, name):
    """Header value by lowercased name ("" if absent). HTTP/2 already sends
    them lowercase, HTTP/1.1 clients may not."""
    for k, v in headers.items():
        if str(k).lower() == name:
            return str(v or "")
    return ""

# ---------------------------------------------------------------------
# Lookup commands
# ---------------------------------------------------------------------

def build_lookups(uid, conn, ip, when):
    """
    (lookup, lookup_safe): one-line shell commands printing this request's
    lines from the three logs, one section each. Values are re-checked
    here; anything that doesn't fit its pattern is left out, and a log with
    nothing safe to search on gets no section. Every grep runs with -a:
    attackers get raw bytes into error.log, and without it grep prints
    "binary file matches" instead of the lines.
    """
    uid = uid if UID_OK.match(uid or "") else ""
    conn = conn if CONN_OK.match(conn or "") else ""
    ip = norm_ip(ip)
    raw, safe = [], []

    def section(title, raw_cmd, safe_cmd):
        raw.append(f"echo '=== {title} ==='; {raw_cmd}")
        safe.append(f"echo '=== {title} ==='; {safe_cmd}")

    if uid:
        grep = f"zgrep -ahF '{uid}' {AUDIT_GLOB}"
        section("modsec_audit.log", f"{grep} | jq .", f"{grep} | jq '{JQ_SAFE}'")

    patterns = " ".join(f"-e '{p}'" for p in (uid, f"{conn} " if conn else "") if p)
    if patterns:
        grep = f"zgrep -ahF {patterns} {ERROR_GLOB}"
        if when:
            # nginx connection ids restart with nginx (nightly reboot)
            grep += f" | grep -aF '{when:%Y/%m/%d} '"
        section("error.log", f"{grep} | sed -E '{SED_PRETTY}'",
                f"{grep} | sed -E '{SED_MASK}; {SED_HIDE}; {SED_PRETTY}'")

    if ip and when:
        minute = f"[{when.day:02d}/{MONTH_NAMES[when.month - 1]}/{when.year}:{when:%H:%M}:"
        grep = f"zgrep -ahF ' {ip} ' {ACCESS_GLOB} | grep -aF '{minute}'"
        section("access.log (same IP, same minute)", grep, f"{grep} | sed -E '{SED_MASK}'")

    if not raw:
        return "", ""
    return "{ " + "; echo; ".join(raw) + "; }", "{ " + "; echo; ".join(safe) + "; }"

# ---------------------------------------------------------------------
# Plugin denials (error.log)
# ---------------------------------------------------------------------

def parse_deny(raw):
    """One error.log line -> denial dict, or None if it isn't one."""
    line = raw.decode("utf-8", "replace").rstrip("\r")
    head = ERR_HEAD_RE.match(line)
    if not head:
        return None
    ts, level, pid, conn, msg = head.groups()
    deny = DENY_RE.match(msg)
    if not deny:
        return None
    phase, plugin, rest = deny.groups()

    reason, client, server, request, tail, truncated = rest, "", "", "", "", False
    ctx = None
    for ctx in CTX_RE.finditer(rest):
        pass
    if ctx:
        reason = rest[:ctx.start()]
        client, server = ctx.group(1), ctx.group(2)
        after = rest[ctx.end():]
        req = REQ_RE.match(after)
        if req:
            request, tail = req.group(1), after[req.end():]
        else:
            # nginx cut the line (2 KB cap) inside the request line
            request, truncated = after, True

    parts = request.split(" ")
    if len(parts) >= 3 and parts[-1].startswith("HTTP/"):
        method, uri, version = parts[0], " ".join(parts[1:-1]), parts[-1][5:]
    elif len(parts) >= 2:
        method, uri, version = parts[0], " ".join(parts[1:]), ""
    else:
        method, uri, version = "", request, ""

    host = HOST_RE.search(tail)
    ref = REF_RE.search(tail)
    try:
        when = datetime.strptime(ts, "%Y/%m/%d %H:%M:%S")
    except ValueError:
        when = None

    return {
        "ts": ts, "when": when, "level": level, "conn": f"{pid}: *{conn}",
        "phase": phase, "plugin": plugin, "reason": reason,
        "client": norm_ip(client) or client, "server": server,
        "method": method, "uri": uri, "http_version": version,
        "truncated": truncated,
        "host": host.group(1) if host else "",
        "referer": ref.group(1) if ref else "",
    }

def deny_event(d):
    """Flat bw_deny event from a parsed denial."""
    path, query = split_uri(d["uri"])
    lookup, lookup_safe = build_lookups("", d["conn"], d["client"], d["when"])
    return {
        "event_type":        DENY_EVENT_TYPE,
        "ts":                d["ts"],
        "srcip":             d["client"],
        "denied_by":         d["plugin"],
        "deny_reason":       cap(d["reason"], VALUE_MAX),
        "deny_phase":        d["phase"].lower(),
        "method":            d["method"],
        "path":              cap(path, URI_MAX),
        "query":             cap(query, URI_MAX),
        "uri":               cap(d["uri"], URI_MAX),
        "http_version":      d["http_version"],
        "request_truncated": "yes" if d["truncated"] else "no",
        "hostname":          cap(d["host"], VALUE_MAX),
        "server":            cap(d["server"], VALUE_MAX),
        "referer":           cap(d["referer"], VALUE_MAX),
        "nginx_conn":        d["conn"],
        "log_level":         d["level"],
        "lookup":            lookup,
        "lookup_safe":       lookup_safe,
    }

class RecentDenials:
    """Denials seen in the last DENY_KEEP_SECONDS, waiting for an audit record."""

    def __init__(self):
        self.items = []   # (monotonic time added, denial)

    def add(self, d):
        self.items.append((time.monotonic(), d))

    def prune(self):
        cutoff = time.monotonic() - DENY_KEEP_SECONDS
        self.items = [(t, d) for t, d in self.items if t >= cutoff]

    def take(self, ip, method, uri, when):
        """Remove and return the closest-in-time denial for this request."""
        best = None
        for i, (_, d) in enumerate(self.items):
            if d["client"] != ip or not d["uri"]:
                continue
            if d["method"] and d["method"] != method:
                continue
            if d["uri"] != uri and not (d["truncated"] and uri.startswith(d["uri"])):
                continue
            gap = DENY_MATCH_SECONDS
            if when and d["when"]:
                gap = abs((d["when"] - when).total_seconds())
                if gap > DENY_MATCH_SECONDS:
                    continue
            if best is None or gap < best[0]:
                best = (gap, i)
        return self.items.pop(best[1])[1] if best else None

# ---------------------------------------------------------------------
# Known attacks (known-attacks.json)
# ---------------------------------------------------------------------

class KnownAttacks:
    """
    The known-attacks.json table, re-read whenever the file changes.

    An entry matches when every "all" condition holds, at least one "any"
    condition holds (if it has any), and no "none" condition holds. A
    condition is {"in": <field>, <op>: <value>}, op one of:
      has      case-insensitive substring
      re       case-insensitive regex (Python syntax)
      equals   case-insensitive whole value
      present  true/false: the field (a header) is there or not
    First matching entry wins, so specific exploits go above the generic
    scan categories. An entry that doesn't parse is skipped and logged; a
    file that doesn't parse keeps the previous table.
    """

    OPS = ("has", "re", "equals", "present")

    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.entries = []
        self.missing_logged = False

    def refresh(self):
        try:
            mtime = self.path.stat().st_mtime
        except OSError as e:
            if not self.missing_logged:
                log(f"{self.path}: not readable ({e}), no known_attack names until it is")
                self.missing_logged = True
            self.entries, self.mtime = [], None
            return
        self.missing_logged = False
        if mtime == self.mtime:
            return
        self.mtime = mtime
        try:
            doc = json.loads(self.path.read_text(encoding="utf-8"))
            raw = doc.get("attacks") if isinstance(doc, dict) else None
            if not isinstance(raw, list):
                raise ValueError('no "attacks" list')
        except (OSError, ValueError) as e:
            log(f"{self.path}: not loaded ({e}), keeping the previous {len(self.entries)} entries")
            return
        entries = []
        for i, item in enumerate(raw):
            try:
                entries.append(self._compile(item))
            except (TypeError, ValueError, KeyError, re.error) as e:
                log(f"{self.path}: skipping entry {i} ({e})")
        self.entries = entries
        log(f"{self.path}: {len(entries)} known attacks loaded")

    def _compile(self, item):
        name = str(item["name"]).strip()
        if not name:
            raise ValueError("empty name")
        groups = {}
        for group in ("all", "any", "none"):
            conds = []
            for c in item.get(group) or []:
                field = str(c["in"]).lower()
                if field not in KNOWN_FIELDS and not field.startswith("header:"):
                    raise ValueError(f"unknown field {field!r}")
                ops = [op for op in self.OPS if op in c]
                if len(ops) != 1:
                    raise ValueError(f"condition on {field!r} needs exactly one of {self.OPS}")
                op, value = ops[0], c[ops[0]]
                if op == "re":
                    value = re.compile(str(value), re.I)
                elif op == "present":
                    value = bool(value)
                else:
                    value = str(value).lower()
                conds.append((field, op, value))
            groups[group] = conds
        if not groups["all"] and not groups["any"]:
            raise ValueError(f"{name!r} has no all/any conditions")
        return {"name": name, "cve": str(item.get("cve") or ""), **groups}

    @staticmethod
    def _holds(cond, ctx):
        field, op, want = cond
        if field.startswith("header:"):
            value = ctx["_headers"].get(field[len("header:"):])
        else:
            value = ctx.get(field)
        if op == "present":
            return (value is not None) == want
        if value is None:
            return False
        if op == "has":
            return want in value.lower()
        if op == "re":
            return bool(want.search(value))
        return value.lower() == want

    def match(self, ctx):
        """(name, cve) of the first matching entry, or ("", "")."""
        for e in self.entries:
            if not all(self._holds(c, ctx) for c in e["all"]):
                continue
            if e["any"] and not any(self._holds(c, ctx) for c in e["any"]):
                continue
            if any(self._holds(c, ctx) for c in e["none"]):
                continue
            return e["name"], e["cve"]
        return "", ""


KNOWN = KnownAttacks(KNOWN_ATTACKS_FILE)

# ---------------------------------------------------------------------
# Transaction flattening
# ---------------------------------------------------------------------

def parse_score(messages, rule_id="949110"):
    """
    Pull a CRS anomaly score from its evaluation rule's message: 949110
    (inbound, the default) or 959100 (outbound, the response). Returns the
    integer score, or 0 if that rule didn't fire (below threshold) or the
    text didn't parse.
    """
    for m in messages:
        details = m.get("details") or {}
        if details.get("ruleId") == rule_id:
            text = "{} {}".format(m.get("message", ""), details.get("data") or "")
            found = SCORE_RE.search(text)
            return int(found.group(1)) if found else 0
    return 0

def band_for(score):
    """Map an anomaly score to a coarse band the manager rules tier on."""
    if score >= SCORE_HIGH_MIN:
        return "high"
    if score >= SCORE_MID_MIN:
        return "mid"
    if score >= 1:
        return "low"
    return "none"

def describe(messages):
    """
    Everything per rule, in one pass: attack types (the suffix of each CRS
    "attack-*" tag: rce, sqli, lfi, ...), the detection rules' descriptions,
    where they matched (variable names only, see WHERE_RE), severities,
    paranoia levels, CAPEC ids, rule files, the full matched data, and one
    readable line per rule.
    """
    out = {k: [] for k in ("attacks", "msgs", "where", "sev", "pl", "capec",
                           "files", "data", "lines")}
    for m in messages:
        details = m.get("details") or {}
        rule = str(details.get("ruleId") or "")
        tags = [t for t in details.get("tags") or [] if isinstance(t, str)]
        data = str(details.get("data") or "")
        sev = SEVERITY_NAMES.get(str(details.get("severity") or ""), "")
        pls = [t[len("paranoia-level/"):] for t in tags if t.startswith("paranoia-level/")]
        detection = not rule.startswith(NON_DETECTION_RULES)

        out["attacks"] += [t[len("attack-"):] for t in tags if t.startswith("attack-")]
        out["capec"] += [t[len("capec/"):] for t in tags if t.startswith("capec/")]
        out["files"].append(Path(str(details.get("file") or "")).stem)
        if detection:
            out["msgs"].append(m.get("message", ""))
            out["sev"].append(sev)
            out["pl"] += pls
            out["data"].append(data)
        found = WHERE_RE.search(data)
        if found:
            out["where"].append(found.group(1))

        line = f"{rule or '?'} {sev or '-'} PL{','.join(pls) or '-'} {m.get('message', '')}"
        extra = data or str(details.get("match") or "")
        out["lines"].append(f"{line} :: {extra}" if extra else line)

    out = {k: unique(v) for k, v in out.items()}
    out["where"] = out["where"][:MAX_WHERE]
    return out

def was_blocked(engine, rule_ids):
    """"yes" if the engine enforces (v3 reports On as "Enabled") and a
    verdict rule fired, else "no". A string so rules can pcre2-match it."""
    enforced = engine in ("On", "Enabled")
    return "yes" if enforced and any(r in VERDICT_RULES for r in rule_ids) else "no"

def flatten(txn, denials):
    """
    Convert one transaction object into the flat dict we ship.

    Tiering / original fields (rules and Discord key on these, keep stable):
      event_type:    "bw_modsec" so rules can scope to this script.
      ts:            modsec's own timestamp string (human read only;
                     Wazuh uses its ingest time for ordering).
      srcip:         real client IP. Wazuh recognizes this name as a
                     static field, so <srcip> rule tags + GeoIP work.
      method/path:   request method and URI path, query in `query`.
      http_code:     final response code. Carried for context, NOT used
                     for tiering (it doesn't track severity here).
      engine:        DetectionOnly vs On, so the alert shows whether the
                     score was enforced or only observed.
      rule_ids:      comma-joined CRS rule IDs that matched (a clean
                     string Wazuh can pcre2-match, unlike the raw array).
      n_rules:       how many rules matched.
      anomaly_score: parsed from 949110; 0 if below threshold.
      outbound_score: parsed from 959100, the RESPONSE's anomaly score
                     (SQL error, stack trace, directory listing, ... in
                     what the server sent back); 0 if below threshold.
      band:          none / low / mid / high (see band_for).
      unique_id:     modsec's transaction id, to cross-ref the raw log.
      hostname:      request Host.
      attacks:       comma-joined CRS attack types (rce, sqli, lfi, ...).
      rule_msgs:     " | "-joined descriptions of the detection rules
                     that matched, de-duplicated.
      matched_in:    comma-joined request variables they matched in
                     (ARGS:path, REQUEST_BODY, ...).
      blocked:       "yes" if modsec itself blocked it (see was_blocked),
                     "no" otherwise. Unlike http_code, a 404/401 from
                     Vaultwarden on a request modsec let through never
                     reads as blocked. A plugin denial is denied_by.
      client_name /  Bitwarden-Client-Name / -Version headers, "" when
      client_version: absent (scanners). Rule 100305 keys on client_name.
      user_agent:    User-Agent header.

    Everything else (filtering + reading):
      uri / query, http_version, client_port, host_port, listener
      (https / http), interrupted; header_names (in the order sent, a
      tool fingerprint), the HEADER_FIELDS headers, req_headers (all),
      req_body + req_body_len; resp_headers (empty values dropped:
      BunkerWeb's header clearing), resp_content_type,
      resp_content_length; severities + max_severity, paranoia_levels,
      capec, rule_files, matched_data (one per line), matches (one
      readable line per rule); modsec_version, crs_version; denied_by /
      deny_reason / nginx_conn when a BunkerWeb plugin denied it;
      known_attack / known_cve from known-attacks.json ("" when nothing
      matched: custom-discord only posts those); via_cf_worker (the
      cf-worker header: the scan came through a Cloudflare Worker, so
      srcip is Cloudflare's, not the scanner's); raw, raw_bytes;
      lookup / lookup_safe.
    """
    req = txn.get("request") or {}
    resp = txn.get("response") or {}
    producer = txn.get("producer") or {}
    messages = [m for m in txn.get("messages") or [] if isinstance(m, dict)]
    req_headers = headers_dict(req.get("headers"))
    resp_headers = headers_dict(resp.get("headers"))

    rule_ids = [(m.get("details") or {}).get("ruleId") for m in messages]
    rule_ids = [r for r in rule_ids if r]
    score = parse_score(messages)
    info = describe(messages)
    uri = str(req.get("uri") or "")
    path, query = split_uri(uri)
    engine = producer.get("secrules_engine", "")
    body = req.get("body")
    body = body if isinstance(body, str) else ("" if body is None else json.dumps(body))
    srcip = txn.get("client_ip", "")
    when = parse_audit_ts(txn.get("time_stamp", ""))
    uid = str(txn.get("unique_id", ""))
    host_port = str(txn.get("host_port", ""))

    denial = denials.take(norm_ip(srcip), req.get("method", ""), uri, when)
    sev_order = list(SEVERITY_NAMES.values())
    severities = [s for s in info["sev"] if s]
    modsec_ver = re.search(r"(\d+\.\d+\.\d+)", str(producer.get("modsecurity") or ""))
    crs_ver = re.search(r"OWASP_CRS/([0-9][0-9A-Za-z.\-]*)",
                        " ".join(str(c) for c in producer.get("components") or []))
    raw = json.dumps(txn, ensure_ascii=False, separators=(",", ":"))
    raw_bytes = len(raw.encode("utf-8", "replace"))
    lookup, lookup_safe = build_lookups(uid, denial["conn"] if denial else "", srcip, when)
    lower_headers = {str(k).lower(): str(v if v is not None else "") for k, v in req_headers.items()}
    known_attack, known_cve = KNOWN.match({
        "method": str(req.get("method") or ""), "path": path, "query": query,
        "uri": uri, "body": deobfuscate(body), "body_raw": body,
        "host": str(req.get("hostname") or ""),
        "ua": lower_headers.get("user-agent", ""),
        "headers": headers_text(req_headers),
        "header_names": ",".join(str(k) for k in req_headers),
        "rules": ",".join(rule_ids), "attacks": ",".join(info["attacks"]),
        "_headers": lower_headers,
    })

    event = {
        "event_type":    EVENT_TYPE,
        "ts":            txn.get("time_stamp", ""),
        "srcip":         srcip,
        "method":        req.get("method", ""),
        "path":          cap(path, URI_MAX),
        "http_code":     resp.get("http_code"),
        "engine":        engine,
        "rule_ids":      ",".join(rule_ids),
        "n_rules":       len(messages),
        "anomaly_score": score,
        "outbound_score": parse_score(messages, "959100"),
        "band":          band_for(score),
        "unique_id":     uid,
        "hostname":      req.get("hostname", ""),
        "attacks":       ",".join(info["attacks"]),
        "rule_msgs":     cap(" | ".join(info["msgs"]), BLOCK_MAX),
        "matched_in":    ",".join(info["where"]),
        "blocked":       was_blocked(engine, rule_ids),
        **{field: cap(header_get(req_headers, name), VALUE_MAX)
           for field, name in HEADER_FIELDS.items()},

        "uri":           cap(uri, URI_MAX),
        "query":         cap(query, URI_MAX),
        "http_version":  req.get("http_version", ""),
        "client_port":   txn.get("client_port"),
        "host_port":     txn.get("host_port"),
        "listener":      LISTENERS.get(host_port, ""),
        "interrupted":   "yes" if txn.get("is_interrupted") else "no",
        "header_names":  cap(",".join(str(k) for k in req_headers), VALUE_MAX),
        "req_headers":   cap(headers_text(req_headers), BLOCK_MAX),
        "req_body":      cap(body, BODY_MAX),
        "req_body_len":  len(body.encode("utf-8", "replace")),
        "resp_headers":  cap(headers_text(resp_headers, skip_empty=True), BLOCK_MAX),
        "resp_content_type":   cap(header_get(resp_headers, "content-type"), VALUE_MAX),
        "resp_content_length": cap(header_get(resp_headers, "content-length"), VALUE_MAX),
        "severities":    ",".join(severities),
        "max_severity":  min(severities, key=sev_order.index) if severities else "",
        "paranoia_levels": ",".join(sorted(info["pl"])),
        "capec":         ",".join(info["capec"]),
        "rule_files":    ",".join(info["files"]),
        "matched_data":  cap("\n".join(info["data"]), BLOCK_MAX),
        "matches":       cap("\n".join(info["lines"]), BLOCK_MAX),
        "modsec_version": modsec_ver.group(1) if modsec_ver else "",
        "crs_version":   crs_ver.group(1) if crs_ver else "",
        "denied_by":     denial["plugin"] if denial else "",
        "deny_reason":   cap(denial["reason"], VALUE_MAX) if denial else "",
        "nginx_conn":    denial["conn"] if denial else "",
        "known_attack":  known_attack,
        "known_cve":     known_cve,
        "via_cf_worker": cap(lower_headers.get("cf-worker", ""), VALUE_MAX),
        "raw":           raw if raw_bytes <= FIELD_MAX else f"[dropped, {raw_bytes} bytes, over the field cap]",
        "raw_bytes":     raw_bytes,
        "lookup":        lookup,
        "lookup_safe":   lookup_safe,
    }
    return event

def to_line(event):
    """JSON line for the event, shrunk per SHRINK_STEPS if over LINE_MAX."""
    line = json.dumps(event, ensure_ascii=False)
    for field, limit in SHRINK_STEPS:
        if len(line.encode("utf-8", "replace")) <= LINE_MAX:
            break
        value = str(event.get(field) or "")
        if not value:
            continue
        size = len(value.encode("utf-8", "replace"))
        event[field] = cap(value, limit) if limit else f"[dropped, {size} bytes, line too big]"
        line = json.dumps(event, ensure_ascii=False)
    return line

# ---------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------

def audit_events(lines, denials):
    """Flatten raw audit-log lines. Malformed ones are skipped (logged to
    journald), never fatal."""
    out = []
    for raw in lines:
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except ValueError as e:
            log(f"skip malformed line: {e}")
            continue
        txn = obj.get("transaction") if isinstance(obj, dict) else None
        if not isinstance(txn, dict):
            continue
        try:
            out.append(to_line(flatten(txn, denials)))
        except (TypeError, ValueError, AttributeError) as e:
            log(f"skip unflattenable record: {e}")
    return out

def deny_events(lines, denials):
    """bw_deny events from raw error.log lines; each denial is also kept
    in `denials` for the audit records that follow."""
    out = []
    for raw in lines:
        d = parse_deny(raw)
        if not d:
            continue
        denials.add(d)
        try:
            out.append(to_line(deny_event(d)))
        except (TypeError, ValueError) as e:
            log(f"skip unformattable denial: {e}")
    return out

def write(lines):
    """Single open() per tick; append mode so copytruncate stays valid."""
    if lines:
        with OUTPUT_LOG.open("a") as f:
            f.write("\n".join(lines) + "\n")

# ---------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------

def main():
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    OUTPUT_LOG.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_LOG.touch(exist_ok=True)

    audit = Tail(AUDIT_LOG, STATE_FILE)
    errlog = Tail(ERROR_LOG, ERROR_STATE_FILE)
    denials = RecentDenials()
    errlog_failing = False

    while not _STOP:
        try:
            # Audit log FIRST: any denial for a record read here is
            # already in error.log by now (see MATCHING above).
            audit_lines = audit.read()

            error_lines = []
            try:
                for _ in range(MAX_ERROR_READS):
                    chunk = errlog.read()
                    if not chunk:
                        break
                    error_lines += chunk
                if errlog_failing:
                    log("error.log readable again")
                    errlog_failing = False
            except OSError as e:
                if not errlog_failing:
                    log(f"error.log unreadable ({e}): no denied_by / bw_deny until it is")
                    errlog_failing = True

            denials.prune()
            KNOWN.refresh()
            out = deny_events(error_lines, denials)
            out += audit_events(audit_lines, denials)
            write(out)
            if audit_lines:
                audit.save()
            if error_lines:
                errlog.save()
        except OSError as e:
            log(f"io error: {e}, retrying next tick")

        # Sleep in small slices so SIGTERM is acted on within ~0.1s.
        slept = 0.0
        while not _STOP and slept < TICK_SECONDS:
            time.sleep(0.1)
            slept += 0.1

if __name__ == "__main__":
    main()
