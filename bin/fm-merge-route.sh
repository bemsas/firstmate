#!/usr/bin/env bash
# fm-merge-route.sh - resolve which home owns a task's pull request before any
# merge, and hand a second mate's green child PR to that mate instead of
# merging it here.
#
# Usage:
#   fm-merge-route.sh <task-id> <pr-url>          resolve only; changes nothing
#   fm-merge-route.sh <task-id> <pr-url> --send [--mandate <text>]
#                                                 resolve, then hand a
#                                                 mate-owned PR to its owner
#   fm-merge-route.sh -h | --help
#
# WHY. bin/fm-pr-merge.sh merges only a task this home records
# (state/<id>.meta). A second mate relays its children's outcomes into its own
# status log (`child <id> <state>: ... pr=<url>`, bin/fm-inactive-reconcile.sh
# and bin/fm-pr-check.sh own those relay lines), but the child's task record
# lives in the mate's home, so calling the guarded merge here with the child's
# id can only refuse with "task metadata is unavailable". This script is the
# one owner of the owner decision that must precede every merge attempt.
#
# OWNER. Exactly one of:
#   main         this home holds a regular, non-symlink state/<id>.meta whose
#                kind is not secondmate, and no registered second mate also
#                relays that child id with this URL: merge here through
#                bin/fm-pr-merge.sh exactly as before.
#   <mate-id>    no ordinary record here, and exactly one registered second
#                mate (state/<mate>.meta with kind=secondmate) has a status
#                line naming `child <id>` together with this exact canonical
#                URL as a whole field (bare, or as `pr=<url>`): hand off.
#   missing      neither: hold; nothing here proves who owns the PR.
#   conflicting  more than one owner claims it (a record here and a relay, or
#                two mates' relays), the id names a second mate itself, or the
#                relaying mate's id is itself the owner word main, missing, or
#                conflicting, which could not be told apart from the owner
#                state: hold.
# The id and URL must pass bin/fm-pr-lib.sh's task-id and canonical-URL
# validation; anything else is a usage error (exit 2).
#
# LIVE FACTS. For a GitHub URL the PR's state, draft flag, head, and base are
# read live through gh, addressed by the full URL so the URL's own host is
# queried whatever GH_HOST is inherited, (bounded by FM_MERGE_ROUTE_GH_SECS, default 10). Other
# forges, and any unreadable read, report head and base as unknown. The
# project is the basename of the record's project= path for a main-owned task,
# and otherwise the one clone under this home's projects/ whose origin remote
# names the same host/owner/repository; none or several is unknown.
# Production is bin/fm-project-mode.sh --production <project> <base>, the one
# owner of that classification, or unknown when either input is unknown.
#
# OUTPUT. key: value lines on stdout, in this order:
#   owner: main|<mate-id>|missing|conflicting
#   pr: <canonical url>
#   state: OPEN|CLOSED|MERGED|unknown          draft: yes|no|unknown
#   head: <sha>|unknown                         base: <branch>|unknown
#   project: <name>|unknown                     production: production|non-production|unknown
#   evidence: <the mate's newest matching relay line>   (mate owner only)
#   route: merge-here|handoff|hold
#   reason: <one sentence>
# Exit 0 for merge-here and handoff, 3 for hold, 2 for usage. Resolution never
# merges, records, or sends anything.
#
# HANDOFF (--send). Only a handoff route sends, and only for an OPEN pull
# request whose head and base were read live; every other route or fact exits
# as resolved without sending. The message goes through bin/fm-send.sh to the
# owning mate, carrying the exact URL, head, base, production classification,
# the relay line as scope evidence, and the current mandate: the away record's
# words verbatim while an away record stands (bin/fm-afk-contract.sh mode),
# else the caller's --mandate text, else the send refuses (exit 3) because a
# handoff without a mandate authorizes nothing. It asks the mate to merge only
# through its own guarded merge pinned to that head, under its own authority
# and holds, and grants nothing: no waiver, force, or bypass rides on it.
# Deduplication: state/.merge-handoffs holds one tab-separated line per
# confirmed send, `<epoch> <mate> <url> <head> <delivery-id>`, written under
# state/.merge-handoffs.lock. A request whose mate, URL, and head are already
# recorded prints `sent: already <epoch>` and sends nothing, so a replayed wake
# never repeats a handoff; a new head is a new handoff. The send uses
# fm-send's --fire-and-forget with a delivery id derived from mate, URL, and
# head, so an unconfirmed send retried by re-running this command lands at most
# one record. The first message built for a delivery id is kept in
# state/.merge-handoffs.pending/<delivery-id> until its send is confirmed, and
# every retry resends that exact message, even when the relay evidence or
# mandate changed meanwhile, because the inbox deduplicates by the whole body;
# a changed mandate for the same head is not a new handoff. Exit 0 after a confirmed or already-recorded send, the send's own
# nonzero status when fm-send could not confirm delivery.
#
# Test seam: FM_MERGE_ROUTE_SEND_CMD replaces bin/fm-send.sh as the send
# command (called with the same arguments), so fixtures never steer a live
# endpoint.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}
case "${1:-}" in -h | --help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
ID=$1
RAW_URL=$2
shift 2
SEND=0
MANDATE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --send) SEND=1; shift ;;
    --mandate)
      [ -n "${2:-}" ] || { echo "error: --mandate requires text" >&2; exit 2; }
      MANDATE=$2; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid merge route request" >&2
  exit 2
fi
URL=$FM_PR_URL

meta_field() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# Owners claiming the task, one per line.
owners=
EVIDENCE=
SELF_MATE=0
RESERVED_MATE=
main_meta="$STATE/$ID.meta"
if [ -f "$main_meta" ] && [ ! -L "$main_meta" ]; then
  if [ "$(meta_field "$main_meta" kind)" = secondmate ]; then
    SELF_MATE=1
  else
    owners="main"
  fi
fi
for mate_meta in "$STATE"/*.meta; do
  [ -f "$mate_meta" ] && [ ! -L "$mate_meta" ] || continue
  [ "$(meta_field "$mate_meta" kind)" = secondmate ] || continue
  mate=$(basename "$mate_meta" .meta)
  status="$STATE/$mate.status"
  [ -f "$status" ] || continue
  line=$(awk -v id="$ID" -v url="$URL" '
    {
      child = 0; hit = 0
      for (i = 1; i < NF; i++) if ($i == "child" && $(i + 1) == id) child = 1
      for (i = 1; i <= NF; i++) if ($i == url || $i == "pr=" url) hit = 1
      if (child && hit) last = $0
    }
    END { if (last != "") print last }
  ' "$status" 2>/dev/null)
  [ -n "$line" ] || continue
  case "$mate" in main|missing|conflicting) RESERVED_MATE=$mate ;; esac
  owners="${owners:+$owners
}$mate"
  EVIDENCE=$line
done
owner_count=0
[ -z "$owners" ] || owner_count=$(printf '%s\n' "$owners" | wc -l | tr -d ' ')

OWNER=missing
if [ "$SELF_MATE" -eq 1 ] || [ -n "$RESERVED_MATE" ] || [ "$owner_count" -gt 1 ]; then
  OWNER=conflicting
elif [ "$owner_count" -eq 1 ]; then
  OWNER=$owners
fi

# Live pull request facts (GitHub only; see LIVE FACTS).
PR_STATE=unknown DRAFT=unknown HEAD=unknown BASE=unknown
if [ "$FM_PR_PROVIDER" = github ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  fm_pr_github_host_export "$FM_PR_HOST"
  if view=$(fm_run_timed "${FM_MERGE_ROUTE_GH_SECS:-10}" gh pr view "$URL" \
      --json state,isDraft,headRefOid,baseRefName </dev/null 2>/dev/null); then
    facts=$(printf '%s' "$view" | jq -r '[(.state // "unknown"), (if .isDraft == true then "yes" elif .isDraft == false then "no" else "unknown" end), (.headRefOid // "unknown"), (.baseRefName // "unknown")] | @tsv' 2>/dev/null) || facts=
    if [ -n "$facts" ]; then
      IFS="$(printf '\t')" read -r PR_STATE DRAFT HEAD BASE <<EOF
$facts
EOF
    fi
  fi
fi
case "$HEAD" in *[!0-9a-f]* | '') HEAD=unknown ;; esac
[ -n "$BASE" ] || BASE=unknown

# The owning project (see LIVE FACTS).
PROJECT=unknown
origin_matches() {  # <remote-url>
  local u=$1
  u=${u%.git}
  u=${u%/}
  case "$u" in
    "https://$FM_PR_HOST/$FM_PR_PATH" | "ssh://git@$FM_PR_HOST/$FM_PR_PATH" | "git@$FM_PR_HOST:$FM_PR_PATH") return 0 ;;
  esac
  return 1
}
if [ "$OWNER" = main ]; then
  proj=$(meta_field "$main_meta" project)
  [ -z "$proj" ] || PROJECT=$(basename "$proj")
elif [ "$OWNER" != conflicting ] && [ -d "$PROJECTS" ]; then
  found=
  for clone in "$PROJECTS"/*/; do
    [ -d "$clone" ] || continue
    remote=$(git -C "$clone" remote get-url origin 2>/dev/null) || continue
    origin_matches "$remote" || continue
    found="${found:+$found
}$(basename "$clone")"
  done
  if [ -n "$found" ] && [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -eq 1 ]; then
    PROJECT=$found
  fi
fi
PRODUCTION=unknown
if [ "$PROJECT" != unknown ] && [ "$BASE" != unknown ]; then
  PRODUCTION=$("$SCRIPT_DIR/fm-project-mode.sh" --production "$PROJECT" "$BASE" 2>/dev/null) || PRODUCTION=unknown
  [ -n "$PRODUCTION" ] || PRODUCTION=unknown
fi

case "$OWNER" in
  main)
    ROUTE=merge-here
    REASON="this home records task $ID; merge only through bin/fm-pr-merge.sh under its usual gates"
    ;;
  missing)
    ROUTE=hold
    REASON="no task record here and no registered second mate relays child $ID with this pull request, so nothing proves who may merge it"
    ;;
  conflicting)
    ROUTE=hold
    if [ "$SELF_MATE" -eq 1 ]; then
      REASON="$ID is a second mate, not the task that opened this pull request; name the child task instead"
    elif [ -n "$RESERVED_MATE" ]; then
      REASON="second mate $RESERVED_MATE relays child $ID, but its id is an owner word this route cannot report unambiguously; rename that mate or hand the pull request off by hand"
    else
      REASON="more than one owner claims child $ID with this pull request: $(printf '%s\n' "$owners" | paste -sd, -)"
    fi
    ;;
  *)
    ROUTE=handoff
    REASON="child $ID belongs to second mate $OWNER, whose home owns its record and its merge; hand it off rather than merging here"
    ;;
esac

printf 'owner: %s\npr: %s\nstate: %s\ndraft: %s\nhead: %s\nbase: %s\nproject: %s\nproduction: %s\n' \
  "$OWNER" "$URL" "$PR_STATE" "$DRAFT" "$HEAD" "$BASE" "$PROJECT" "$PRODUCTION"
[ "$ROUTE" != handoff ] || printf 'evidence: %s\n' "$EVIDENCE"
printf 'route: %s\nreason: %s\n' "$ROUTE" "$REASON"

if [ "$ROUTE" = hold ]; then
  exit 3
fi
[ "$SEND" -eq 1 ] || exit 0
if [ "$ROUTE" != handoff ]; then
  echo "sent: no (this home owns the task; nothing is handed off)"
  exit 0
fi
if [ "$PR_STATE" != OPEN ] || [ "$HEAD" = unknown ] || [ "$BASE" = unknown ]; then
  echo "sent: no (the pull request is not readably open at a known head and base; nothing is handed off)"
  exit 3
fi
if fm_afk_contract_away_present "$STATE"; then
  MANDATE=$("$SCRIPT_DIR/fm-afk-contract.sh" words 2>/dev/null) || {
    echo "sent: no (the away record's words could not be read)"
    exit 3
  }
  MANDATE="away words, verbatim: ${MANDATE:-(none recorded)}"
elif [ -z "$MANDATE" ]; then
  echo "sent: no (no away record stands and no --mandate was given, so the handoff would authorize nothing)"
  exit 3
fi

LEDGER="$STATE/.merge-handoffs"
LEDGER_LOCK="$STATE/.merge-handoffs.lock"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_acquire_wait_max "$LEDGER_LOCK" 30 || {
  echo "sent: no (the handoff ledger lock is busy; re-run to retry)"
  exit 3
}
trap 'fm_lock_release "$LEDGER_LOCK" || true' EXIT
TAB=$(printf '\t')
prior=$(awk -F "$TAB" -v m="$OWNER" -v u="$URL" -v h="$HEAD" '$2 == m && $3 == u && $4 == h { print $1; exit }' "$LEDGER" 2>/dev/null)
if [ -n "$prior" ]; then
  echo "sent: already $prior"
  exit 0
fi
hash_text="merge-handoff|$OWNER|$URL|$HEAD"
if command -v shasum >/dev/null 2>&1; then
  DELIVERY=$(printf '%s' "$hash_text" | shasum -a 256 | cut -c1-16)
else
  DELIVERY=$(printf '%s' "$hash_text" | sha256sum | cut -c1-16)
fi
MESSAGE="Merge handoff from the parent home: child task $ID is yours, so the parent will not merge it.
PR: $URL
Head: $HEAD
Base: $BASE
Production (parent registry, by base): $PRODUCTION
Scope evidence (your relay line): $EVIDENCE
Parent mandate: $MANDATE
Merge it only through your own bin/fm-pr-merge.sh $ID $URL --expected-head $HEAD, under your own merge authority, checks, and holds; if they do not cover it, hold and relay why. This handoff waives no check, forces nothing, and authorizes nothing your own rules do not."
PENDING="$STATE/.merge-handoffs.pending/$DELIVERY"
if [ -f "$PENDING" ]; then
  MESSAGE=$(cat "$PENDING") || { echo "sent: no (the pending handoff $DELIVERY could not be read)"; exit 3; }
else
  mkdir -p "${PENDING%/*}" && printf '%s' "$MESSAGE" > "$PENDING.tmp" && mv -f "$PENDING.tmp" "$PENDING" || {
    rm -f "$PENDING.tmp"
    echo "sent: no (the pending handoff $DELIVERY could not be recorded)"
    exit 3
  }
fi
SEND_CMD=${FM_MERGE_ROUTE_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
FM_HOME=$FM_HOME "$SEND_CMD" "$OWNER" --fire-and-forget "$DELIVERY" "$MESSAGE"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "sent: unconfirmed (fm-send exit $rc; re-run this command to retry the same delivery $DELIVERY)"
  exit "$rc"
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$OWNER" "$URL" "$HEAD" "$DELIVERY" >> "$LEDGER"
rm -f "$PENDING"
echo "sent: yes $DELIVERY"
