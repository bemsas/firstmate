#!/usr/bin/env bash
# fm-hermes-inbox.sh - post one Hermes note into the main firstmate inbox.
#
# Hermes desktop, ops, and trix call this through bin/fm-hermes-inbox-entry.sh.
# post writes one note with bin/fm-inbox.sh note. read looks that note up
# with bin/fm-inbox.sh receipts and prints only its recorded reply.
# The exchange log is bin/fm-hermes-bridge-lib.sh.
# The sender is always hermes. The profile is desktop, ops, or trix, and it must
# match HERMES_HOME when that variable names a profile directory.
# The request id is hermes.<profile>.<correlation>. A second post with the
# same id returns the original note. A different message for that id is refused.
# The message is read from --message-file or stdin and is never evaluated.
# This script does not send mail, post publicly, direct-message anyone, or
# spend money. It never calls the model-backed inbox commands.
#
# Exit codes:
#   0  note created or replayed, or a reply was printed
#   2  usage or validation
#   3  the note is saved but was not announced, or no reply is available
#   1  the inbox call or the exchange log failed
#
# Usage:
#   fm-hermes-inbox.sh post --profile desktop|ops|trix --corr <16-hex> [--message-file <path>]
#   fm-hermes-inbox.sh read --profile desktop|ops|trix --corr <16-hex>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-hermes-bridge-lib.sh
. "$SCRIPT_DIR/fm-hermes-bridge-lib.sh"

umask 077

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-hermes-inbox.sh post --profile desktop|ops|trix --corr <16-hex> [--message-file <path>]
  fm-hermes-inbox.sh read --profile desktop|ops|trix --corr <16-hex>
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Post one Hermes note through fm-inbox.sh, or read its recorded reply.

--profile desktop, --profile ops, and --profile trix are the only accepted profiles.
--corr is 16 hex characters and becomes the inbox request id
hermes.<profile>.<correlation>.
post reads the note from --message-file or from stdin and does not evaluate it.
read prints one JSON object. A missing note or a note with no reply exits 3.
A second post of the same correlation returns the original note.
A different message for that correlation is refused.
The script calls fm-inbox.sh note, receipts, and no other inbox command.
EOF
}

require_home() {
  local home=${FM_HOME:-}
  case "$home" in
    /*) ;;
    *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
  esac
  [ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }
  [ ! -L "$home" ] || { printf '%s\n' 'error: FM_HOME must not be a symlink' >&2; exit 2; }
}

require_python() {
  command -v python3 >/dev/null 2>&1 || {
    printf '%s\n' 'error: python3 is required' >&2
    exit 1
  }
}

read_body_or_die() {  # [path]
  local path=${1-} body rc=0
  body=$(fm_hermes_bridge_read_body "$path") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2) printf '%s\n' 'error: message file is not a regular file' >&2 ;;
      3) printf '%s\n' 'error: message exceeds the size bound' >&2 ;;
      4) printf '%s\n' 'error: message is empty' >&2 ;;
      5) printf '%s\n' 'error: message contains a NUL byte' >&2 ;;
      *) printf '%s\n' 'error: message could not be read' >&2 ;;
    esac
    exit 2
  fi
  case "${body//[[:space:]]/}" in
    '') printf '%s\n' 'error: message is empty' >&2; exit 2 ;;
  esac
  printf '%s' "$body"
}

enforce_profile_home() {  # <profile>
  local home=${HERMES_HOME:-} base name
  [ -n "$home" ] || return 0
  home=${home%/}
  base=${home%/*}
  name=${home##*/}
  case "$base" in
    */profiles) ;;
    *) printf '%s\n' 'error: HERMES_HOME is not a named profile directory' >&2; exit 2 ;;
  esac
  case "$name" in
    desktop|ops|trix) ;;
    *) printf '%s\n' 'error: HERMES_HOME profile must be desktop, ops, or trix' >&2; exit 2 ;;
  esac
  if [ "$name" != "$1" ]; then
    printf '%s\n' 'error: --profile does not match HERMES_HOME' >&2
    exit 2
  fi
}

note_body_for() {  # <profile> <corr> <message>
  printf 'sender: hermes\nprofile: %s\ncorrelation: %s\n\n%s' "$1" "$2" "$3"
}

emit_result() {  # json file is already written; print it
  cat "$1"
  printf '\n'
}

log_or_die() {  # direction outcome code request reply
  fm_hermes_bridge_log_exchange hermes "$exchange" "$corr" "$topic" "$profile" \
    "$1" "$2" "$3" "$4" "${5-}" "" || {
    printf '%s\n' 'error: exchange log failed' >&2
    exit 1
  }
}

parse_note_json() {  # <src> <dest>
  require_python
  python3 - "$1" "$2" <<'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
try:
    data = json.loads(open(src, encoding="utf-8").read() or "")
except (OSError, json.JSONDecodeError):
    sys.exit(1)
if not isinstance(data, dict) or data.get("schema") != "fm-inbox-note.v1":
    sys.exit(1)
out = {
    "outcome": data.get("outcome"),
    "id": data.get("id"),
    "request_id": data.get("request_id"),
    "saved": data.get("saved") is True,
    "announced": data.get("announced") is True,
    "acknowledged": data.get("acknowledged") is True,
}
open(dest, "w", encoding="utf-8").write(json.dumps(out))
PY
}

lookup_reply() {  # <receipts> <request-id> <profile> <corr> <dest>
  require_python
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
src, request_id, profile, corr, dest = sys.argv[1:6]
try:
    data = json.loads(open(src, encoding="utf-8").read() or "")
except (OSError, json.JSONDecodeError):
    json.dump({"status": "bad-receipts"}, open(dest, "w", encoding="utf-8"))
    sys.exit(0)
if not isinstance(data, dict) or data.get("schema") != "fm-inbox-receipts.v1":
    json.dump({"status": "bad-receipts"}, open(dest, "w", encoding="utf-8"))
    sys.exit(0)
prefix = "sender: hermes\nprofile: %s\ncorrelation: %s\n\n" % (profile, corr)
matches = []
for bucket in ("pending", "handled"):
    rows = data.get(bucket) or []
    if not isinstance(rows, list):
        json.dump({"status": "bad-receipts"}, open(dest, "w", encoding="utf-8"))
        sys.exit(0)
    for note in rows:
        if isinstance(note, dict) and note.get("request_id") == request_id:
            matches.append(note)
if not matches:
    json.dump({"status": "missing"}, open(dest, "w", encoding="utf-8"))
    sys.exit(0)
if len(matches) != 1:
    json.dump({"status": "ambiguous"}, open(dest, "w", encoding="utf-8"))
    sys.exit(0)
note = matches[0]
body = note.get("body")
if not isinstance(body, str) or not body.startswith(prefix):
    json.dump({"status": "mismatch", "note_id": note.get("id")}, open(dest, "w", encoding="utf-8"))
    sys.exit(0)
reply = note.get("reply")
result = {"status": "pending", "note_id": note.get("id")}
if isinstance(reply, dict) and isinstance(reply.get("body"), str) and reply.get("body") != "":
    result = {"status": "reply", "note_id": note.get("id"), "reply": reply["body"]}
json.dump(result, open(dest, "w", encoding="utf-8"))
PY
}

json_field() {  # <file> <field>
  require_python
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
value = data.get(sys.argv[2])
if value is None:
    sys.exit(0)
sys.stdout.write(value if isinstance(value, str) else json.dumps(value))
PY
}

write_public_json() {  # <dest> <action> <outcome> <note-id> [reply]
  local dest=$1 action=$2 outcome=$3 note_id=$4 reply=${5-}
  require_python
  ACTION=$action OUTCOME=$outcome NOTE_ID=$note_id REPLY=$reply \
    PROFILE=$profile CORR=$corr REQUEST_ID=$request_id python3 - "$dest" <<'PY'
import json, os, sys
out = {
    "schema": "fm-hermes-inbox.v1",
    "action": os.environ["ACTION"],
    "profile": os.environ["PROFILE"],
    "correlation_id": os.environ["CORR"],
    "request_id": os.environ["REQUEST_ID"],
    "note_id": os.environ["NOTE_ID"] or None,
    "outcome": os.environ["OUTCOME"],
}
if os.environ["ACTION"] == "read" and os.environ["OUTCOME"] == "reply":
    out["reply"] = os.environ["REPLY"]
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=True, separators=(",", ":")))
PY
}

valid_note_id() {
  case "$1" in
    ''|*/*|*[[:space:]]*|*..*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

do_post() {  # <message>
  local message=$1 note_body inbox_rc=0 outcome note_id got_request announced acknowledged public stored
  note_body=$(note_body_for "$profile" "$corr" "$message")
  : > "$work/note-out"
  set +e
  printf '%s' "$note_body" | FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-inbox.sh" \
    note --request-id "$request_id" --json - >"$work/note-out" 2>"$work/note-err"
  inbox_rc=$?
  set -e
  if ! parse_note_json "$work/note-out" "$work/note.json"; then
    log_or_die inbound inbox-failed 1 "$message" ""
    printf '%s\n' 'error: fm-inbox.sh note did not return a note record' >&2
    exit 1
  fi
  outcome=$(json_field "$work/note.json" outcome)
  note_id=$(json_field "$work/note.json" id)
  got_request=$(json_field "$work/note.json" request_id)
  announced=$(json_field "$work/note.json" announced)
  acknowledged=$(json_field "$work/note.json" acknowledged)
  valid_note_id "$note_id" || {
    log_or_die inbound inbox-failed 1 "$message" ""
    printf '%s\n' 'error: fm-inbox.sh note returned an unusable note id' >&2
    exit 1
  }
  [ "$got_request" = "$request_id" ] || {
    log_or_die inbound inbox-failed 1 "$message" ""
    printf '%s\n' 'error: fm-inbox.sh note returned a different request id' >&2
    exit 1
  }
  case "$outcome" in
    created|replay) ;;
    *)
      log_or_die inbound inbox-failed 1 "$message" ""
      printf '%s\n' 'error: fm-inbox.sh note returned an unknown outcome' >&2
      exit 1
      ;;
  esac
  if [ "$outcome" = replay ]; then
    : > "$work/receipts"
    FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-inbox.sh" receipts \
      --all-pending --all-handled --all-replies >"$work/receipts" 2>"$work/receipts-err" || {
      log_or_die inbound inbox-failed 1 "$message" ""
      printf '%s\n' 'error: fm-inbox.sh receipts failed during replay' >&2
      exit 1
    }
    lookup_reply "$work/receipts" "$request_id" "$profile" "$corr" "$work/lookup.json"
    case "$(json_field "$work/lookup.json" status)" in
      pending|reply) ;;
      *)
        log_or_die inbound conflict 2 "$message" ""
        printf '%s\n' 'error: correlation already belongs to a different note' >&2
        exit 2
        ;;
    esac
    stored=$(python3 - "$work/receipts" "$request_id" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
request_id = sys.argv[2]
for bucket in ("pending", "handled"):
    for note in data.get(bucket) or []:
        if isinstance(note, dict) and note.get("request_id") == request_id:
            body = note.get("body") or ""
            marker = "\n\n"
            idx = body.find(marker)
            sys.stdout.write(body[idx + len(marker):] if idx >= 0 else "")
            raise SystemExit
PY
)
    if [ "$stored" != "$message" ]; then
      log_or_die inbound conflict 2 "$message" ""
      printf '%s\n' 'error: correlation already used with a different message' >&2
      exit 2
    fi
  fi
  public=created
  if [ "$outcome" = replay ]; then
    public=replay
  fi
  if [ "$announced" != true ] && [ "$acknowledged" != true ]; then
    public=unannounced
    inbox_rc=3
  elif [ "$inbox_rc" -ne 0 ]; then
    inbox_rc=0
  fi
  write_public_json "$work/public.json" post "$public" "$note_id"
  log_or_die inbound "$public" "$inbox_rc" "$message" ""
  emit_result "$work/public.json"
  printf 'exchange=%s\n' "$exchange" >&2
  exit "$inbox_rc"
}

do_read() {
  local status note_id reply_text
  : > "$work/receipts"
  if ! FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-inbox.sh" receipts \
    --all-pending --all-handled --all-replies >"$work/receipts" 2>"$work/receipts-err"; then
    log_or_die read inbox-failed 1 "" ""
    printf '%s\n' 'error: fm-inbox.sh receipts failed' >&2
    exit 1
  fi
  lookup_reply "$work/receipts" "$request_id" "$profile" "$corr" "$work/lookup.json"
  status=$(json_field "$work/lookup.json" status)
  note_id=$(json_field "$work/lookup.json" note_id || true)
  case "$status" in
    missing)
      write_public_json "$work/public.json" read missing ""
      log_or_die read missing 3 "" ""
      emit_result "$work/public.json"
      printf 'exchange=%s\n' "$exchange" >&2
      exit 3
      ;;
    pending)
      valid_note_id "$note_id" || {
        log_or_die read inbox-failed 1 "" ""
        printf '%s\n' 'error: receipt note id is unusable' >&2
        exit 1
      }
      write_public_json "$work/public.json" read pending "$note_id"
      log_or_die read pending 3 "" ""
      emit_result "$work/public.json"
      printf 'exchange=%s\n' "$exchange" >&2
      exit 3
      ;;
    reply)
      valid_note_id "$note_id" || {
        log_or_die read inbox-failed 1 "" ""
        printf '%s\n' 'error: receipt note id is unusable' >&2
        exit 1
      }
      reply_text=$(json_field "$work/lookup.json" reply)
      write_public_json "$work/public.json" read reply "$note_id" "$reply_text"
      log_or_die read reply 0 "" "$reply_text"
      emit_result "$work/public.json"
      printf 'exchange=%s\n' "$exchange" >&2
      exit 0
      ;;
    *)
      log_or_die read inbox-failed 1 "" ""
      printf '%s\n' 'error: reply lookup failed' >&2
      exit 1
      ;;
  esac
}

action='' profile='' corr='' message_file=''
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  help_text
  exit 0
fi
case "${1:-}" in
  post|read) action=$1; shift ;;
  *) usage ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) help_text; exit 0 ;;
    --profile)
      [ "$#" -ge 2 ] || usage
      profile=$2
      shift 2
      ;;
    --corr)
      [ "$#" -ge 2 ] || usage
      corr=$2
      shift 2
      ;;
    --message-file)
      [ "$#" -ge 2 ] || usage
      message_file=$2
      shift 2
      ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ "$#" -eq 0 ] || usage

fm_hermes_bridge_corr_ok "$corr" || { printf '%s\n' 'error: corr must be 16 hex characters' >&2; exit 2; }
corr=$(printf '%s' "$corr" | tr 'A-F' 'a-f')
topic=$(fm_hermes_bridge_topic_for_profile "$profile") || {
  printf '%s\n' 'error: profile must be desktop, ops, or trix' >&2
  exit 2
}
require_home
enforce_profile_home "$profile"
if [ "$action" = read ] && [ -n "$message_file" ]; then
  usage
fi

request_id="hermes.${profile}.${corr}"
exchange=$(fm_hermes_bridge_new_id) || { printf '%s\n' 'error: could not generate an exchange id' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermes-inbox.XXXXXX") || exit 1
chmod 700 "$work"
# shellcheck disable=SC2064 # work is a fixed temp dir for this process
trap "rm -rf -- $(printf '%q' "$work")" EXIT

if [ "$action" = post ]; then
  message=$(read_body_or_die "$message_file")
  do_post "$message"
fi
do_read
