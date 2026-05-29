#!/usr/bin/env python3
"""
modsec-tail.py: BunkerWeb ModSecurity JSON audit log -> Wazuh log shipper.

Tails BunkerWeb's modsec_audit.log (JSON audit format, one transaction
object per line), flattens each transaction into a single flat JSON
line with clean scalar fields, and appends it to
/var/log/modsec-events/events.log. The Wazuh agent on this VM tails
that file via a <localfile> entry; the manager fires rules
100300 / 100301 / 100302 / 100303 (see
Vaultwarden/wazuh-home/manager-modsec-rules.xml) on the decoded events.

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

ARCHITECTURE

  Vault VM                                   wazuh-home (manager)
  --------                                   -------------------
  bunkerweb container (rootless podman)
    ModSecurity writes /var/log/bunkerweb/modsec_audit.log
                                ^
                                | bind mount to host /srv/bw-logs
                                |
  modsec-tail.py (this script)
    poll the audit log every TICK seconds from a saved byte offset
    -> flatten each transaction -> append JSON line to
       /var/log/modsec-events/events.log
                                ^
                                | tailed by Wazuh agent
                                |
  wazuh-agent
    ships event over encrypted channel to wazuh-home
                                ^
                                v
                                rules 100300 / 100301 / 100302 / 100303 fire
                                100300 (level 0):  every modsec event, archived
                                100301 (level 3):  band=none  (probe / redirect noise)
                                100302 (level 7):  band=low|mid (routine scoring scans)
                                100303 (level 11): band=high (real multi-vector attack)

STATE

  Byte offset into modsec_audit.log persisted at STATE_FILE so the
  daemon resumes exactly where it left off across restarts: no dropped
  events, no replays. On first run (no state file) we start at the
  current end of the file, skipping the historical backlog. Rotation
  via copytruncate is detected by the file shrinking below our offset;
  a rotate-rename is detected by the inode changing.

CONFIG

  Edit the constants below for your environment. Defaults match the
  reference setup documented in Vaultwarden/wazuh-home/README.md.

SAFETY

  Reads the audit log (attacker-controlled, byte-dirty payloads) only
  via json.loads, which treats every field as an inert string. The
  script never shells out (no subprocess / os.system / eval), so a
  payload can never escape into a command context. stdlib only.
"""

import json
import re
import signal
import sys
import time
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

OUTPUT_LOG = Path("/var/log/modsec-events/events.log")
"""
Where this script appends flat JSON-per-line events. The Wazuh agent
on this VM tails this file; see
Vaultwarden/wazuh-home/vault-modsec-agent.localfile.xml.

Own subdirectory so logrotate can target the dir cleanly. Rotation
config deployed by hand to /etc/logrotate.d/modsec-events; canonical
text in Vaultwarden/README.md. Daily, keep 14, compress, copytruncate.
Opened in append mode so copytruncate keeps our writes landing at EOF.
"""

STATE_FILE = Path("/var/lib/modsec-tail/offset")
"""
Persists the last processed byte offset across restarts. Atomic write
via a `.tmp` rename so a crash mid-write can't truncate it to zero.
"""

TICK_SECONDS = 2
"""
Polling interval. The audit log only grows on a CRS match (RelevantOnly)
and stays small, so a tight 2s tick is cheap and keeps Discord latency
low. The loop wakes every 0.1s to stay responsive to SIGTERM.
"""

MAX_READ_BYTES = 8 * 1024 * 1024
"""
Cap on bytes pulled per tick. Bounds catch-up cost / memory after a
long downtime. The next tick continues from the advanced offset.
"""

EVENT_TYPE = "bw_modsec"
"""
Discriminator embedded in every event so manager rules scope to "events
from this script" via <field name="event_type">bw_modsec</field>,
independent of the location path. Keep stable; rules match on it.
"""

# CRS anomaly-score band thresholds. Tier boundaries the manager rules
# key on via the `band` field. Picked from observed data: routine
# secret-file scanning scores 5-10, real multi-vector attacks score
# 30-55, with a clean gap. Retune here if your traffic differs.
SCORE_MID_MIN = 10    # score >= this -> "mid"
SCORE_HIGH_MIN = 30   # score >= this -> "high" (the Discord tier)

# 949110's message reads "Inbound Anomaly Score Exceeded (Total Score: N)".
SCORE_RE = re.compile(r"Total Score:\s*(\d+)")

# ---------------------------------------------------------------------
# Shutdown flag
# ---------------------------------------------------------------------

_STOP = False

def _handle_stop(signum, _frame):
    """SIGTERM/SIGINT -> finish the current tick and exit cleanly."""
    global _STOP
    _STOP = True

# ---------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------

def load_offset():
    """Return the saved byte offset, or None on first run."""
    try:
        return int(STATE_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None

def save_offset(value):
    """Atomically persist the byte offset (temp file + rename)."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(STATE_FILE)

# ---------------------------------------------------------------------
# Transaction flattening
# ---------------------------------------------------------------------

def parse_score(messages):
    """
    Pull the CRS inbound anomaly score from rule 949110's message.
    Returns the integer score, or 0 if 949110 didn't fire (below
    threshold) or the text didn't parse.
    """
    for m in messages:
        details = m.get("details") or {}
        if details.get("ruleId") == "949110":
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

def flatten(txn):
    """
    Convert one transaction object into the flat dict we ship.

    Field choices:
      event_type:    "bw_modsec" so rules can scope to this script.
      ts:            modsec's own timestamp string (human read only;
                     Wazuh uses its ingest time for ordering).
      srcip:         real client IP. Wazuh recognizes this name as a
                     static field, so <srcip> rule tags + GeoIP work.
      method/path:   request method and URI with the query string
                     STRIPPED (a query could carry a token from a
                     legit false-positive request; cross-ref the full
                     record in modsec_audit.log by unique_id if needed).
      http_code:     final response code. Carried for context, NOT used
                     for tiering (it doesn't track severity here).
      engine:        DetectionOnly vs On, so the alert shows whether the
                     score was enforced or only observed.
      rule_ids:      comma-joined CRS rule IDs that matched (a clean
                     string Wazuh can pcre2-match, unlike the raw array).
      n_rules:       how many rules matched.
      anomaly_score: parsed from 949110; 0 if below threshold.
      band:          none / low / mid / high (see band_for).
      unique_id:     modsec's transaction id, to cross-ref the raw log.
      hostname:      request Host.
    """
    req = txn.get("request") or {}
    resp = txn.get("response") or {}
    producer = txn.get("producer") or {}
    messages = txn.get("messages") or []

    rule_ids = [(m.get("details") or {}).get("ruleId") for m in messages]
    rule_ids = [r for r in rule_ids if r]
    score = parse_score(messages)
    uri = req.get("uri") or ""

    return {
        "event_type":    EVENT_TYPE,
        "ts":            txn.get("time_stamp", ""),
        "srcip":         txn.get("client_ip", ""),
        "method":        req.get("method", ""),
        "path":          uri.split("?", 1)[0],
        "http_code":     resp.get("http_code"),
        "engine":        producer.get("secrules_engine", ""),
        "rule_ids":      ",".join(rule_ids),
        "n_rules":       len(messages),
        "anomaly_score": score,
        "band":          band_for(score),
        "unique_id":     txn.get("unique_id", ""),
        "hostname":      req.get("hostname", ""),
    }

# ---------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------

def read_new(state):
    """
    Read complete new lines from the audit log since the saved offset.

    Handles rotation: copytruncate (file shrinks below our offset ->
    reset to 0) and rotate-rename (inode changes -> reset to 0). Leaves
    a trailing partial line (no newline yet) for the next tick so we
    never parse half a record. Returns (list_of_byte_lines, new_state).
    """
    try:
        st = AUDIT_LOG.stat()
    except FileNotFoundError:
        # bunkerweb not up yet; nothing to do this tick.
        return [], state

    offset = state["offset"]
    if state.get("ino") != st.st_ino:
        offset = 0
    if st.st_size < offset:
        offset = 0
    if st.st_size == offset:
        return [], {"offset": offset, "ino": st.st_ino}

    with AUDIT_LOG.open("rb") as f:
        f.seek(offset)
        data = f.read(MAX_READ_BYTES)

    last_nl = data.rfind(b"\n")
    if last_nl == -1:
        # only a partial line available so far; don't advance.
        return [], {"offset": offset, "ino": st.st_ino}

    complete = data[:last_nl + 1]
    new_offset = offset + len(complete)
    lines = [ln for ln in complete.split(b"\n") if ln.strip()]
    return lines, {"offset": new_offset, "ino": st.st_ino}

def emit(lines):
    """
    Flatten each raw JSON line and append the result to OUTPUT_LOG.
    Malformed lines are skipped (logged to journald), never fatal.
    Single open() per tick; append mode so copytruncate stays valid.
    """
    out = []
    for raw in lines:
        try:
            obj = json.loads(raw.decode("utf-8", "replace"))
        except ValueError as e:
            print(f"skip malformed line: {e}", file=sys.stderr)
            continue
        txn = obj.get("transaction") if isinstance(obj, dict) else None
        if not txn:
            continue
        try:
            out.append(json.dumps(flatten(txn), ensure_ascii=False))
        except (TypeError, ValueError, AttributeError) as e:
            print(f"skip unflattenable record: {e}", file=sys.stderr)
    if out:
        with OUTPUT_LOG.open("a") as f:
            f.write("\n".join(out) + "\n")

# ---------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------

def main():
    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    OUTPUT_LOG.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_LOG.touch(exist_ok=True)

    offset = load_offset()
    if offset is None:
        # First run: start at EOF so we don't replay the existing log.
        offset = AUDIT_LOG.stat().st_size if AUDIT_LOG.exists() else 0
        save_offset(offset)
        print(f"first run, starting at offset={offset}", file=sys.stderr)

    ino = AUDIT_LOG.stat().st_ino if AUDIT_LOG.exists() else None
    state = {"offset": offset, "ino": ino}

    while not _STOP:
        try:
            lines, state = read_new(state)
            if lines:
                emit(lines)
                save_offset(state["offset"])
        except OSError as e:
            print(f"io error: {e}, retrying next tick", file=sys.stderr)

        # Sleep in small slices so SIGTERM is acted on within ~0.1s.
        slept = 0.0
        while not _STOP and slept < TICK_SECONDS:
            time.sleep(0.1)
            slept += 0.1

if __name__ == "__main__":
    main()
