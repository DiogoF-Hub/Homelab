#!/usr/bin/env python3
"""
pihole-ftl-tail.py: Pi-hole FTL DB -> Wazuh log shipper.

Polls Pi-hole's FTL SQLite database (`pihole-FTL.db`) on a tick, picks
up new query rows since the last processed `id`, formats each as a
JSON line, and appends to /var/log/vault-dns/events.log. Wazuh agent
on this VM tails that file via a <localfile> entry; the manager fires
rule 100250 / 100251 / 100252 (see Vaultwarden/wazuh-home/manager-rules.xml)
on the resulting decoded events.

WHY THIS EXISTS

Pi-hole's dnsmasq text log (/var/log/pihole/pihole.log) emits four-plus
different syntactic patterns for "this query was blocked" depending on
the source: gravity (adlist), exactly denied (manual), regex denied,
blocked-upstream-with-NULL, externally-blocked (NXDOMAIN), and so on.
Pi-hole versions reword these and add new flavors over time. Building
a Wazuh decoder regex that catches every variant and stays correct
across upgrades is whack-a-mole.

The FTL SQLite DB on the other hand has a normalized `status` integer
column that knows authoritatively what happened, regardless of how
the dnsmasq text log phrased it. Reading it directly gives us exactly
one event per resolved query, with status / qtype / client / domain
in well-defined fields and stable types. That is what this script
ships.

ARCHITECTURE

  Pi-hole VM                                wazuh-home (manager)
  -----------                                -------------------
  pihole container
    pihole-FTL writes /etc/pihole/pihole-FTL.db
                                ^
                                | bind mount to host
                                |
  pihole-ftl-tail.py (this script)
    poll queries view every TICK seconds, filter by Vault VM client
    -> append JSON line to /var/log/vault-dns/events.log
                                ^
                                | tailed by Wazuh agent
                                |
  wazuh-agent
    ships event over encrypted channel to wazuh-home
                                ^
                                v
                                rules 100250 / 100251 / 100252 fire
                                100250 (level 0): every Vault DNS event, archived
                                100251 (level 3): resolved (forwarded / cached / etc)
                                100252 (level 6): blocked (any flavor)

STATE

  Last-processed query `id` is persisted at STATE_FILE so the daemon
  picks up from the right offset across restarts. On first run (no
  state file) we start from the current max id (skip historical
  backlog so we don't double-emit weeks of history).

CONFIG

  Edit the constants below for your environment. The defaults match
  the reference setup documented in Vaultwarden/wazuh-home/README.md.
"""

import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

FTL_DB = Path("/home/pi/pihole/data/etc-pihole/pihole-FTL.db")
"""
Path to Pi-hole's FTL SQLite DB on the host. The Pi-hole container
bind-mounts /etc/pihole from this host path; if your bind mount is
elsewhere, adjust here.
"""

OUTPUT_LOG = Path("/var/log/vault-dns/events.log")
"""
Where this script appends JSON-per-line events. The Wazuh agent on
this VM tails this file; see Vaultwarden/wazuh-home/pihole-agent.localfile.xml.

Lives in its own subdirectory so logrotate can target the dir cleanly
without globbing /var/log/. Rotation config: deployed by hand to
/etc/logrotate.d/vault-dns; canonical text in Vaultwarden/README.md
§ Log Rotation → LAN Pi-hole VM. Daily, keep 14, compress,
copytruncate.
"""

STATE_FILE = Path("/var/lib/pihole-ftl-tail/last_seen_id")
"""
Persists the last processed `id` from the queries view across restarts.
Atomic write via a `.tmp` rename, so a crash mid-write can't truncate
to zero.
"""

CLIENT_FILTER = "192.168.50.3"
"""
Only emit events for this client IP (the Vault VM). Set to the empty
string to emit for all clients on the LAN. Filtering at SQL level
keeps the JSON log small and cheaper for Wazuh to ingest.
"""

TICK_SECONDS = 10
"""
Polling interval. FTL writes to its DB every few seconds in normal
operation; 10s feels near-real-time without thrashing the disk.
"""

BATCH_LIMIT = 5000
"""
Max rows pulled per tick. Caps catch-up cost after a long downtime
or a first start with backlog. Subsequent ticks process the next batch.
"""

EVENT_TYPE = "vault_dns"
"""
Discriminator field embedded in every JSON event so manager-side rules
can scope to "events from this script" without depending on the
location path or other fragile signals. Keep stable; rules match on it.
"""

# ---------------------------------------------------------------------
# Mappings: integer codes -> human-readable labels.
# Anything not listed falls back to "type-N" / "status-N" so the data
# never gets lost; we just see the raw code in the dashboard.
# ---------------------------------------------------------------------

QTYPE_LABELS = {
    1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 7: "MB", 10: "NULL",
    12: "PTR", 15: "MX", 16: "TXT", 17: "RP", 18: "AFSDB", 24: "SIG",
    25: "KEY", 28: "AAAA", 29: "LOC", 33: "SRV", 35: "NAPTR",
    36: "KX", 37: "CERT", 39: "DNAME", 41: "OPT", 43: "DS",
    44: "SSHFP", 46: "RRSIG", 47: "NSEC", 48: "DNSKEY", 50: "NSEC3",
    51: "NSEC3PARAM", 52: "TLSA", 53: "SMIMEA", 55: "HIP", 59: "CDS",
    60: "CDNSKEY", 61: "OPENPGPKEY", 62: "CSYNC", 63: "ZONEMD",
    64: "SVCB", 65: "HTTPS", 99: "SPF", 105: "L32", 106: "L64",
    107: "LP", 108: "EUI48", 109: "EUI64", 249: "TKEY", 250: "TSIG",
    251: "IXFR", 252: "AXFR", 256: "URI", 257: "CAA",
}

# FTL status codes -> labels. Source: Pi-hole 6 FTL enums (enum.h /
# enums.h in the FTL source). Confirmed against probe data on the
# reference Pi-hole 6 instance: codes 5 (denied exact), 7 (upstream
# NULL), 17 (externally-blocked NULL reply) all observed.
STATUS_LABELS = {
    0:  "unknown",
    1:  "blocked-gravity",
    2:  "forwarded",
    3:  "cached",
    4:  "blocked-regex",
    5:  "blocked-deny-exact",
    6:  "blocked-upstream-ip",
    7:  "blocked-upstream-null",
    8:  "blocked-upstream-nxdomain",
    9:  "blocked-gravity-cname",
    10: "blocked-regex-cname",
    11: "blocked-deny-cname",
    12: "retried",
    13: "retried-ignored",
    14: "forwarded-dnssec-bogus",
    15: "blocked-external-ip-null",
    16: "blocked-external-nxdomain",
    17: "blocked-external-null-reply",
    18: "blocked-special-domain",
    19: "cached-stale",
    20: "blocked-deny-exact-cname",
}

# Status codes that mean the query did NOT resolve to a real answer.
# Used to set a single boolean `blocked` field per event so dashboard
# filtering doesn't have to enumerate all the block flavors.
BLOCKED_STATUSES = {1, 4, 5, 6, 7, 8, 9, 10, 11, 15, 16, 17, 18, 20}

# ---------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------

def load_last_seen():
    """
    Return the last processed query `id` from the state file. If the
    file doesn't exist, return None (caller treats this as first-run
    and starts from current-max-id, skipping the historical backlog).
    """
    try:
        return int(STATE_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None

def save_last_seen(value):
    """
    Atomically persist `value` to STATE_FILE. Writes to a temp file
    then renames; a crash mid-write can't leave the state file
    truncated.
    """
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(STATE_FILE)

# ---------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------

def open_db():
    """
    Open FTL's SQLite DB read-only. WAL mode (FTL's default) lets us
    read concurrently with FTL's writes without blocking; mode=ro on
    the URI guarantees we can never accidentally write even if the
    program has a bug. Short timeout so a transient lock doesn't hang
    the daemon for tens of seconds.
    """
    uri = f"file:{FTL_DB}?mode=ro&cache=shared"
    conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    conn.row_factory = sqlite3.Row
    return conn

def current_max_id(conn):
    """
    Return the largest `id` currently in the queries view. Used on
    first run (no state file) so we don't replay the full long-term
    history into Wazuh as a giant backlog.
    """
    row = conn.execute("SELECT MAX(id) AS m FROM queries").fetchone()
    return row["m"] or 0

def fetch_new_rows(conn, last_id):
    """
    Pull queries with `id` strictly greater than `last_id`, optionally
    filtered to one client, capped at BATCH_LIMIT to bound per-tick
    work. The next tick picks up where this one left off.
    """
    sql = (
        "SELECT id, timestamp, type, status, domain, client, forward "
        "FROM queries WHERE id > ?"
    )
    params = [last_id]
    if CLIENT_FILTER:
        sql += " AND client = ?"
        params.append(CLIENT_FILTER)
    sql += " ORDER BY id ASC LIMIT ?"
    params.append(BATCH_LIMIT)
    return conn.execute(sql, params).fetchall()

# ---------------------------------------------------------------------
# Event formatting
# ---------------------------------------------------------------------

def format_event(row):
    """
    Convert one queries-view row into a JSON line for /var/log/vault-dns/events.log.

    Field choices:
      event_type: "vault_dns" so Wazuh rules can scope to events from
                  this script via <field name="event_type">vault_dns</field>.
      ts:         ISO-8601 with timezone, derived from FTL's unix
                  timestamp. Wazuh ignores this in favor of its own
                  ingest time, but it's useful for human reads.
      pi_id:      The FTL row id. Useful for correlating back to the
                  source DB if you ever need to dig deeper.
      srcip:      Client IP. Wazuh recognizes this name as a static
                  field, so <srcip> rule tags work as expected.
      qtype:      Human label (A, AAAA, ...).
      qtype_code: Raw integer for unrecognized types.
      query:      The queried domain.
      status:     Human label (forwarded, cached, blocked-gravity, ...).
      status_code: Raw integer.
      blocked:    Boolean, computed from BLOCKED_STATUSES.
      forward:    Upstream destination string when known, else "".
                  NULL in the DB for blocked / cached queries.
    """
    ts = datetime.fromtimestamp(row["timestamp"], tz=timezone.utc).astimezone()
    qtype_n = row["type"]
    status_n = row["status"]
    return json.dumps({
        "event_type":   EVENT_TYPE,
        "ts":           ts.isoformat(timespec="seconds"),
        "pi_id":        row["id"],
        "srcip":        row["client"],
        "qtype":        QTYPE_LABELS.get(qtype_n, f"type-{qtype_n}"),
        "qtype_code":   qtype_n,
        "query":        row["domain"],
        "status":       STATUS_LABELS.get(status_n, f"status-{status_n}"),
        "status_code":  status_n,
        "blocked":      status_n in BLOCKED_STATUSES,
        "forward":      row["forward"] or "",
    }, ensure_ascii=False)

def write_events(rows):
    """
    Append formatted events to OUTPUT_LOG. Single open() per tick so
    we're not paying file-open cost per row. logrotate-friendly:
    `copytruncate` mode keeps the inode and our open handle stays
    valid; standard rotate-rename mode means the next tick reopens.
    """
    with OUTPUT_LOG.open("a") as f:
        for row in rows:
            f.write(format_event(row) + "\n")

# ---------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------

def tick(conn, last_id):
    """
    One polling cycle: fetch new rows, write them out, return the new
    high-water-mark id. Returns the input `last_id` unchanged if there
    were no new rows.
    """
    rows = fetch_new_rows(conn, last_id)
    if not rows:
        return last_id
    write_events(rows)
    return rows[-1]["id"]

def main():
    OUTPUT_LOG.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_LOG.touch(exist_ok=True)

    conn = open_db()

    last_id = load_last_seen()
    if last_id is None:
        # First run: skip historical backlog so we don't replay weeks
        # of queries in one go. Subsequent runs use the persisted id.
        last_id = current_max_id(conn)
        save_last_seen(last_id)
        print(f"first run, starting from id={last_id}", file=sys.stderr)

    while True:
        try:
            new_last = tick(conn, last_id)
        except sqlite3.Error as e:
            # FTL might be mid-rotation, schema-migration, or the DB
            # could have been replaced (e.g. user restored from backup).
            # Reopen on the next tick rather than killing the daemon.
            print(f"sqlite error: {e}, reopening on next tick", file=sys.stderr)
            try:
                conn.close()
            except Exception:
                pass
            time.sleep(TICK_SECONDS)
            conn = open_db()
            continue

        if new_last != last_id:
            save_last_seen(new_last)
            last_id = new_last

        time.sleep(TICK_SECONDS)

if __name__ == "__main__":
    main()
