#!/usr/bin/env bash
# fm-cost-ledger.sh - per-task cost and quality ledger for query by firstmate.
#
# Usage:
#   fm-cost-ledger.sh record <task-id>
#   fm-cost-ledger.sh query [--harness <name>] [--task <id>] [--since <epoch>] [--json]
#
# record appends one JSON object per line to data/cost-ledger.jsonl, at most once
# per task incarnation (task id plus spawn_gen). Recording is disabled unless
# config/cost-ledger is present; then this command exits before reading task
# metadata or the ledger.
# bin/fm-teardown.sh calls record for every ship and scout task whose local copy
# it cleans up, immediately after optional pipeline-spend recording and before
# the task branch is removed. The ledger is private and gitignored with data/.
#
# docs/cost-ledger.md owns the public record contract and query shape.
# Exit status: 0 when a record was written or already present, on an empty query,
# or when recording is disabled; 1 when the task record is missing, names a
# secondmate, or the record could not be built or written; 2 for bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-cost-ledger: %s\n' "$*" >&2
  exit 1
}

cmd=${1:-}
case "$cmd" in
  -h|--help) usage; exit 0 ;;
  record)
    shift
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    ;;
  query)
    shift
    ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$cmd" = record ]; then
  ID=$1
  fm_task_id_path_safe "$ID" || { echo "fm-cost-ledger: invalid task id" >&2; exit 2; }
  [ -e "$CONFIG/cost-ledger" ] || exit 0
  META="$STATE/$ID.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || fail "no task record for $ID"
  meta_value() {
    grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
  }
  kind=$(meta_value kind)
  [ "$kind" != secondmate ] || fail "$ID is a secondmate, not a task"
  [ -d "$DATA" ] || fail "data directory $DATA is missing"
  STATUS="$STATE/$ID.status"
  LEDGER="$DATA/cost-ledger.jsonl"
  PIPELINE="$DATA/pipeline-spend.jsonl"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    python3 - "$LEDGER" "$ID" "$META" "$STATUS" "$PIPELINE" <<'PY' || fail "could not build the cost ledger record for $ID"
import fcntl
import json
import os
import re
import sys
import time
from pathlib import Path

ledger, task_id, meta_path, status_path, pipeline_path = sys.argv[1:6]


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def meta_map(path):
    out = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key] = value
    return out


def status_verb(line):
    head = line.split(":", 1)[0]
    head = re.sub(r"\[at=\d+\]", "", head)
    return head.strip()


def parse_epoch(line):
    match = re.search(r"\[at=(\d+)\]", line)
    return int(match.group(1)) if match else None


def analyze_status(path):
    counts = {
        "needs-decision": 0,
        "blocked": 0,
        "paused": 0,
        "resolved": 0,
        "working": 0,
        "done": 0,
        "failed": 0,
    }
    first_at = None
    outcome = None
    outcome_at = None
    terminal = 0
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        text = ""
    for line in text.splitlines():
        if not line.strip():
            continue
        verb = status_verb(line)
        if verb in counts:
            counts[verb] += 1
        ts = parse_epoch(line)
        if ts is not None and first_at is None:
            first_at = ts
        if verb in ("done", "failed"):
            terminal += 1
            outcome = verb
            if ts is not None:
                outcome_at = ts
    rework = max(0, terminal - 1) if terminal else 0
    return counts, outcome, first_at, outcome_at, rework


def load_pipeline(task, spawn_gen, path):
    if not Path(path).is_file():
        return None
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            if row.get("task") == task and row.get("spawn_gen") == spawn_gen:
                total = row.get("total")
                if total is None and row.get("source") == "unavailable":
                    return {"source": "unavailable", "reason": row.get("reason")}
                if isinstance(total, dict):
                    return {"source": row.get("source", "no-mistakes-state"), "total": total}
                return None
    except OSError:
        return None
    return None


meta = meta_map(meta_path)
spawn_gen = meta.get("spawn_gen")
project = meta.get("project") or ""
if project:
    project = os.path.basename(project.rstrip("/"))
counts, outcome, first_at, outcome_at, rework = analyze_status(status_path)
pipeline = load_pipeline(task_id, spawn_gen, pipeline_path)

record = {
    "v": 1,
    "task": task_id,
    "spawn_gen": spawn_gen,
    "recorded_at": utc(time.time()),
    "harness": meta.get("harness"),
    "model": meta.get("model"),
    "effort": meta.get("effort"),
    "profile": None,
    "kind": meta.get("kind"),
    "project": project or None,
    "mode": meta.get("mode"),
    "outcome": outcome,
    "quality": {
        "needs_decision": counts["needs-decision"],
        "blocked": counts["blocked"],
        "paused": counts["paused"],
        "resolved": counts["resolved"],
        "rework": rework,
    },
    "spend": {
        "worker": "unknown",
        "pipeline": pipeline,
    },
    "timing": {
        "first_status_at": utc(first_at) if first_at else None,
        "outcome_at": utc(outcome_at) if outcome_at else None,
        "duration_sec": (outcome_at - first_at) if first_at and outcome_at and outcome_at >= first_at else None,
    },
}

line = json.dumps(record, separators=(",", ":"))

try:
    fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        content = handle.read()
        for existing in content.splitlines():
            try:
                row = json.loads(existing)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("task") == task_id and row.get("spawn_gen") == spawn_gen:
                print("already recorded %s %s" % (task_id, spawn_gen or "-"))
                sys.exit(0)
        handle.write(("\n" if content and not content.endswith("\n") else "") + line + "\n")
        handle.flush()
        os.fsync(handle.fileno())
except OSError as err:
    sys.stderr.write("fm-cost-ledger: cannot write %s: %s\n" % (ledger, err))
    sys.exit(1)
print("recorded %s %s" % (task_id, spawn_gen or "-"))
PY
  exit 0
fi

# query
HARNESS=
FILTER_TASK=
SINCE=
JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      FILTER_TASK=$2
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SINCE=$2
      shift 2
      ;;
    --json) JSON=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

LEDGER="$DATA/cost-ledger.jsonl"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
python3 - "$LEDGER" "$HARNESS" "$FILTER_TASK" "$SINCE" "$JSON" <<'PY'
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

ledger, harness, task_filter, since_s, json_out = sys.argv[1:6]
json_out = json_out == "1"
since = int(since_s) if since_s else None
records = []
path = Path(ledger)
if path.is_file():
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        if harness and row.get("harness") != harness:
            continue
        if task_filter and row.get("task") != task_filter:
            continue
        if since is not None:
            recorded = row.get("recorded_at") or ""
            try:
                epoch = int(datetime.strptime(recorded, "%Y-%m-%dT%H:%M:%SZ").timestamp())
            except ValueError:
                continue
            if epoch < since:
                continue
        records.append(row)

by_harness = defaultdict(lambda: {"tasks": 0, "outcome": defaultdict(int), "quality": defaultdict(int)})
for row in records:
    h = row.get("harness") or "unknown"
    bucket = by_harness[h]
    bucket["tasks"] += 1
    outcome = row.get("outcome") or "unknown"
    bucket["outcome"][outcome] += 1
    quality = row.get("quality") or {}
    for key in ("needs_decision", "blocked", "paused", "resolved", "rework"):
        bucket["quality"][key] += int(quality.get(key) or 0)

payload = {
    "schema": "fm-cost-ledger-query.v1",
    "records": records,
    "by_harness": {k: dict(v, outcome=dict(v["outcome"]), quality=dict(v["quality"])) for k, v in sorted(by_harness.items())},
}

if json_out:
    print(json.dumps(payload, separators=(",", ":")))
    sys.exit(0)

if not records:
    print("no matching cost ledger records")
    sys.exit(0)

for row in records:
    q = row.get("quality") or {}
    print(
        "%s\t%s\t%s\toutcome=%s\trework=%s\tneeds_decision=%s\tblocked=%s"
        % (
            row.get("task"),
            row.get("harness"),
            row.get("recorded_at"),
            row.get("outcome") or "-",
            q.get("rework", 0),
            q.get("needs_decision", 0),
            q.get("blocked", 0),
        )
    )
PY
