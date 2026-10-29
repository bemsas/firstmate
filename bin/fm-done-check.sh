#!/usr/bin/env bash
# Code-checked done checklist for a ship worker's PR, run when the worker reports
# done with a PR. fm-pr-check.sh calls it before arming merge monitoring;
# fm-watch.sh calls --auto on complete, newly observed ship done: lines with one PR.
# Usage: fm-done-check.sh [--auto] <task-id> <pr-url>
# --auto atomically stamps canonical pr= into ship metadata, even with the
# checklist off, and pr_head= when the enabled checklist can read a valid head.
# It shares the metadata lock with fm-pr-check.sh and never arms a merge poll.
#
# Switch: FM_DONE_CHECK, else the first non-comment line of config/done-check
# (under FM_CONFIG_OVERRIDE or $FM_HOME/config). Values:
#   off     (default; absent, empty, or any unrecognized value) - exit 0; only --auto binds pr=.
#   shadow  compute the verdict, append it to state/done-check.log, never steer, always exit 0.
#   on      as shadow, and a failed checklist steers the worker back through fm-send.
#
# Checks (GitHub only; each is pass, fail, unknown, or skip):
#   base       PR base equals the intended base: FM_DONE_CHECK_BASE, meta base=, or the
#              brief's "## Base branch" section; skipped when none is declared.
#   mergeable  the forge does not report CONFLICTING/DIRTY, and a local
#              git merge-tree of head onto origin/<base> is clean.
#   vision     VISION.md is unchanged between the merge base and the PR head.
#   trailers   no AI co-author trailer and no "Generated with <AI>" footer in the PR's commits.
#   scope      every changed file matches a glob in the brief's "## Files in scope"
#              section (bullets; `dir/` is a prefix); skipped when the brief has none.
#   tests      every command in the brief's "## Tests" section (bullets; first `code span`,
#              else the whole bullet) was run. Evidence is data/<id>/receipt.json
#              ({head_sha, tests:[{cmd, exit}]}; a missing command or nonzero exit fails),
#              else data/<id>/report.md or tests.log mentioning the command; with no
#              evidence file the check is unknown. A receipt head that differs from the
#              PR head is noted, not failed, because a validation pipeline may add commits.
#   proof      the ready report (the task's last done: line in state/<id>.status)
#              carries the visual-proof rider bin/fm-dod-lib.sh's Definition of
#              done requires on UI changes. A declared `proof=<path>[,...]` names
#              comma-separated files that must each exist, be non-empty, and end
#              in a visual extension (png jpg jpeg webp gif bmp tif tiff mp4
#              webm mov mkv, case-insensitive); `proof=none` declares that
#              nothing user-visible changed. With no rider - including an
#              unreadable status file - the check fails when the PR's changed
#              files end in a UI extension (css scss sass less html htm tsx jsx
#              vue svelte svg, case-insensitive) and skips otherwise; a missing
#              worktree or base ref is unknown, never a bounce.
# Git reads run in the task's worktree against refs already there; nothing is fetched.
# An unreadable fact is unknown, never a failure: unknown never bounces.
#
# Bounce limit: at most 2 steers per task (state/<id>.done-check holds bounces= and
# last_head=). A failure on a head already bounced re-reports without a second steer;
# a failure after the limit exits 11 so firstmate escalates instead of steering again.
# A steer that fm-send does not confirm is not counted and exits 3.
#
# Output: one JSON verdict on stdout, a human summary on stderr.
# Exit: 0 pass / off / shadow, 10 bounced to the worker, 11 escalate to firstmate,
# 3 unknown (nothing could be decided; proceed as today), 2 usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BOUNCE_LIMIT=2

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

AUTO=0
if [ "${1:-}" = --auto ]; then AUTO=1; shift; fi
if [ "$#" -ne 2 ]; then
  echo "usage: fm-done-check.sh [--auto] <task-id> <pr-url>" >&2
  exit 2
fi
ID=$1
RAW_URL=$2

done_check_mode() {
  local value=${FM_DONE_CHECK-} line
  if [ -z "$value" ] && [ -f "$CONFIG/done-check" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      value=$line
      break
    done < "$CONFIG/done-check"
  fi
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$value" in
    shadow|on) printf '%s\n' "$value" ;;
    *) printf 'off\n' ;;
  esac
}

MODE=$(done_check_mode)
[ "$MODE" != off ] || [ "$AUTO" -eq 1 ] || exit 0

if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid done check request" >&2
  exit 2
fi
URL=$FM_PR_URL

# Automatic done ingestion binds the PR even when the optional checklist is off.
# Use the same task metadata lock as fm-pr-check; no merge poll is armed here.
stamp_pr() {  # [head]
  local lock tmp device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$STATE/$ID.meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if [ ! -f "$STATE/$ID.meta" ] || [ -L "$STATE/$ID.meta" ] \
    || [ "$(fm_pr_file_link_count "$STATE/$ID.meta")" != 1 ] \
    || [ "$(sed -n 's/^kind=//p' "$STATE/$ID.meta")" != ship ]; then
    fm_lock_release "$lock"
    return 1
  fi
  device=$(fm_pr_file_device "$STATE") || { fm_lock_release "$lock"; return 1; }
  tmp=$(umask 077; mktemp "$STATE/.fm-done-meta.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if awk '!/^(pr|pr_head)=/' "$STATE/$ID.meta" > "$tmp" \
    && printf 'pr=%s\n' "$URL" >> "$tmp" \
    && { [ -z "${1:-}" ] || printf 'pr_head=%s\n' "$1" >> "$tmp"; } \
    && fm_pr_private_file_valid "$tmp" 600 "$device" \
    && fm_pr_regular_destination_on_device_or_absent "$STATE/$ID.meta" "$device" \
    && mv -f -- "$tmp" "$STATE/$ID.meta"; then
    fm_lock_release "$lock"
    return 0
  fi
  rm -f -- "$tmp"
  fm_lock_release "$lock"
  return 1
}
if [ "$AUTO" -eq 1 ]; then
  stamp_pr || { echo 'error: could not bind the ship task PR' >&2; exit 3; }
fi
[ "$MODE" != off ] || exit 0

RESULTS=
note() {  # <name> <pass|fail|unknown|skip> <detail>
  local detail
  detail=$(printf '%s' "$3" | tr '\t\n' '  ')
  RESULTS="${RESULTS}$1	$2	${detail}
"
}

unknown_exit() {  # <reason>
  echo "done check: unknown - $1; proceeding as without the checklist" >&2
  printf '{"verdict":"unknown","reason":%s}\n' "$(printf '%s' "$1" | jq -Rs . 2>/dev/null || printf '""')"
  exit 3
}

command -v jq >/dev/null 2>&1 || unknown_exit "jq is unavailable"
[ "$FM_PR_PROVIDER" = github ] || unknown_exit "only GitHub pull requests are checked"
command -v gh >/dev/null 2>&1 || unknown_exit "gh is unavailable"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || unknown_exit "task metadata is unavailable"
meta_get() { grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true; }
WT=$(meta_get worktree)
BRIEF="$DATA/$ID/brief.md"

PR_JSON=$(gh pr view "$URL" --json baseRefName,headRefOid,mergeable,mergeStateStatus 2>/dev/null) \
  || unknown_exit "the forge could not be read"
BASE=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // empty' 2>/dev/null) || BASE=
HEAD=$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // empty' 2>/dev/null) || HEAD=
MERGEABLE=$(printf '%s' "$PR_JSON" | jq -r '.mergeable // empty' 2>/dev/null) || MERGEABLE=
MERGE_STATE=$(printf '%s' "$PR_JSON" | jq -r '.mergeStateStatus // empty' 2>/dev/null) || MERGE_STATE=
fm_pr_head_valid "$HEAD" || unknown_exit "the forge returned no usable head commit"
[ -n "$BASE" ] || unknown_exit "the forge returned no base branch"
if [ "$AUTO" -eq 1 ]; then
  stamp_pr "$HEAD" || unknown_exit "the task PR head could not be recorded"
fi

# Text of a "## <heading>" section, up to the next heading at the same or higher level.
brief_section() {  # <heading>
  [ -f "$BRIEF" ] || return 0
  awk -v want="$1" '
    /^# / { on = 0; next }
    /^## / { sub(/^## */, ""); sub(/[ \t]+$/, ""); on = (tolower($0) == tolower(want)); next }
    on { print }
  ' "$BRIEF"
}

# Bullet items of a section, one per line: the first `code span` when present, else the bullet text.
section_items() {  # <heading>
  brief_section "$1" | while IFS= read -r line; do
    case "$line" in
      '- '*|'* '*|[0-9].' '*|[0-9][0-9].' '*) ;;
      *) continue ;;
    esac
    item=$(printf '%s' "$line" | sed -e 's/^[-*][[:space:]]*//' -e 's/^[0-9][0-9]*\.[[:space:]]*//')
    # shellcheck disable=SC2016 # Literal Markdown code-span delimiters.
    case "$item" in
      *'`'*'`'*) item=$(printf '%s' "$item" | sed -e 's/^[^`]*`//' -e 's/`.*$//') ;;
    esac
    item=$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$item" ] || printf '%s\n' "$item"
  done
}

# --- base ---------------------------------------------------------------
WANT_BASE=$(meta_get base_branch)
[ -n "$WANT_BASE" ] || WANT_BASE=$(meta_get base)
WANT_BASE=${FM_DONE_CHECK_BASE:-$WANT_BASE}
if [ -z "$WANT_BASE" ]; then
  WANT_BASE=$(brief_section 'Base branch' | sed -e '/^[[:space:]]*$/d' -e 's/`//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -1)
fi
if [ -z "$WANT_BASE" ]; then
  note base skip "no intended base is declared"
elif [ "$BASE" = "$WANT_BASE" ]; then
  note base pass "targets $BASE"
else
  note base fail "the PR targets $BASE but the brief names $WANT_BASE; retarget it to $WANT_BASE"
fi

# --- git facts from the task worktree -------------------------------------
GIT_OK=1
BASE_REF="origin/$BASE"
if [ -z "$WT" ] || [ ! -d "$WT" ] || ! git -C "$WT" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_OK=0
  GIT_WHY="the task worktree is unavailable"
elif ! git -C "$WT" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
  GIT_OK=0
  GIT_WHY="$BASE_REF is not present in the task worktree"
elif ! git -C "$WT" cat-file -e "$HEAD^{commit}" 2>/dev/null; then
  GIT_OK=0
  GIT_WHY="PR head $HEAD is not present in the task worktree"
fi

# --- mergeable ------------------------------------------------------------
MERGE_FAIL=
case "$MERGEABLE:$MERGE_STATE" in
  CONFLICTING:*|*:DIRTY) MERGE_FAIL="the forge reports the PR conflicts with $BASE (mergeable=$MERGEABLE state=$MERGE_STATE)" ;;
esac
if [ -z "$MERGE_FAIL" ] && [ "$GIT_OK" = 1 ]; then
  MT_RC=0
  git -C "$WT" merge-tree --write-tree "$BASE_REF" "$HEAD" >/dev/null 2>&1 || MT_RC=$?
  [ "$MT_RC" != 1 ] || MERGE_FAIL="merging the PR head into $BASE_REF conflicts locally"
fi
if [ -n "$MERGE_FAIL" ]; then
  note mergeable fail "$MERGE_FAIL; rebase onto $BASE and resolve the conflicts"
elif [ "$GIT_OK" = 1 ] || [ "$MERGEABLE" = MERGEABLE ]; then
  note mergeable pass "no conflict with $BASE"
else
  note mergeable unknown "forge mergeable=${MERGEABLE:-unset}; $GIT_WHY"
fi

# --- vision / trailers / scope --------------------------------------------
if [ "$GIT_OK" = 1 ]; then
  VISION_RC=0
  git -C "$WT" diff --quiet "$BASE_REF...$HEAD" -- VISION.md 2>/dev/null || VISION_RC=$?
  case "$VISION_RC" in
    0) note vision pass "VISION.md is unchanged" ;;
    1) note vision fail "VISION.md differs from $BASE_REF; restore it with git checkout $BASE_REF -- VISION.md" ;;
    *) note vision unknown "VISION.md could not be compared" ;;
  esac

  BAD_TRAILERS=$(git -C "$WT" log --format='%h%n%B%n--' "$BASE_REF..$HEAD" 2>/dev/null \
    | grep -iE '^(co-authored-by:.*(claude|anthropic|openai|chatgpt|codex|copilot|gemini|cursor|\[bot\])|.*generated (with|by) .*(claude|anthropic|codex|chatgpt|openai|gemini|copilot|cursor))' \
    | head -3 || true)
  if [ -n "$BAD_TRAILERS" ]; then
    note trailers fail "an AI co-author trailer or generated-by footer is in the commit messages ($(printf '%s' "$BAD_TRAILERS" | tr '\n' ';')); reword those commits without it"
  else
    note trailers pass "no AI trailer in the PR commits"
  fi

  GLOBS=$(section_items 'Files in scope')
  if [ -z "$GLOBS" ]; then
    note scope skip "the brief declares no files in scope"
  else
    OUT_OF_SCOPE=
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      matched=0
      while IFS= read -r glob; do
        case "$glob" in */) glob="${glob}*" ;; esac
        # shellcheck disable=SC2254
        case "$file" in $glob) matched=1; break ;; esac
      done <<GLOBS_EOF
$GLOBS
GLOBS_EOF
      [ "$matched" = 1 ] || OUT_OF_SCOPE="${OUT_OF_SCOPE}${OUT_OF_SCOPE:+, }$file"
    done <<FILES_EOF
$(git -C "$WT" diff --name-only "$BASE_REF...$HEAD" 2>/dev/null)
FILES_EOF
    if [ -n "$OUT_OF_SCOPE" ]; then
      note scope fail "files outside the brief's scope: $OUT_OF_SCOPE; drop those changes or ask firstmate to widen the scope"
    else
      note scope pass "every changed file is in scope"
    fi
  fi
else
  note vision unknown "$GIT_WHY"
  note trailers unknown "$GIT_WHY"
  note scope unknown "$GIT_WHY"
fi

# --- tests ----------------------------------------------------------------
TESTS=$(section_items 'Tests')
if [ -z "$TESTS" ]; then
  note tests skip "the brief names no tests"
else
  RECEIPT="$DATA/$ID/receipt.json"
  TEXT_EVIDENCE=
  for f in "$DATA/$ID/report.md" "$DATA/$ID/tests.log"; do
    [ ! -f "$f" ] || TEXT_EVIDENCE="${TEXT_EVIDENCE}${TEXT_EVIDENCE:+ }$f"
  done
  MISSING=
  HEAD_NOTE=
  EVIDENCE=1
  if [ -f "$RECEIPT" ] && jq -e '.tests | type == "array"' "$RECEIPT" >/dev/null 2>&1; then
    RECEIPT_HEAD=$(jq -r '.head_sha // empty' "$RECEIPT")
    [ -z "$RECEIPT_HEAD" ] || [ "$RECEIPT_HEAD" = "$HEAD" ] \
      || HEAD_NOTE=" (receipt head ${RECEIPT_HEAD:0:8} differs from PR head ${HEAD:0:8})"
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      ran=$(jq -r --arg c "$cmd" '[.tests[] | select((.cmd | gsub("[[:space:]]+"; " ")) == ($c | gsub("[[:space:]]+"; " ")))] | if length == 0 then "missing" elif all(.[]; .exit == 0) then "ok" else "failed" end' "$RECEIPT")
      case "$ran" in
        ok) ;;
        failed) MISSING="${MISSING}${MISSING:+; }'$cmd' exited nonzero" ;;
        *) MISSING="${MISSING}${MISSING:+; }'$cmd' is not in the receipt" ;;
      esac
    done <<TESTS_EOF
$TESTS
TESTS_EOF
  elif [ -n "$TEXT_EVIDENCE" ]; then
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      # shellcheck disable=SC2086
      grep -qF -- "$cmd" $TEXT_EVIDENCE 2>/dev/null || MISSING="${MISSING}${MISSING:+; }'$cmd' is not in the report or log"
    done <<TESTS_EOF
$TESTS
TESTS_EOF
  else
    EVIDENCE=0
  fi
  if [ "$EVIDENCE" = 0 ]; then
    note tests unknown "no receipt, report, or test log under data/$ID to read"
  elif [ -n "$MISSING" ]; then
    note tests fail "tests the brief names were not shown passing: $MISSING; run them and record the result in data/$ID/receipt.json"
  else
    note tests pass "every named test ran${HEAD_NOTE}"
  fi
fi

# --- proof ----------------------------------------------------------------
# The visual-proof rider: bin/fm-dod-lib.sh's Definition of done tells the
# worker to end a UI change's ready report - the task's final done: line -
# with `proof=<paths>` or `proof=none`. This check verifies the rider without
# re-teaching it: a declared rider must name real screenshot/video files, and
# an absent rider fails only when the PR itself changes UI-extension files.
proof_path_is_visual() {  # <path>
  local v=$1
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    *.png|*.jpg|*.jpeg|*.webp|*.gif|*.bmp|*.tif|*.tiff|*.mp4|*.webm|*.mov|*.mkv) return 0 ;;
    *) return 1 ;;
  esac
}
PROOF_STATUS="$STATE/$ID.status"
PROOF_DONE_LINE=
if [ -f "$PROOF_STATUS" ] && [ ! -L "$PROOF_STATUS" ]; then
  PROOF_DONE_LINE=$(grep -E '^done([[:space:]]|:|\[)' "$PROOF_STATUS" 2>/dev/null | tail -1)
fi
PROOF_TOKEN=
if [ -n "$PROOF_DONE_LINE" ]; then
  PROOF_TOKEN=$(printf '%s\n' "$PROOF_DONE_LINE" | tr ' ' '\n' | sed -n 's/^proof=//p' | tail -1)
fi
if [ "$PROOF_TOKEN" = none ]; then
  note proof pass "the ready report declares proof=none: no user-visible change"
elif [ -n "$PROOF_TOKEN" ]; then
  BAD_PROOF=
  PROOF_REST=$PROOF_TOKEN
  while [ -n "$PROOF_REST" ]; do
    PROOF_ONE=${PROOF_REST%%,*}
    if [ "$PROOF_ONE" = "$PROOF_REST" ]; then PROOF_REST=; else PROOF_REST=${PROOF_REST#*,}; fi
    if [ -f "$PROOF_ONE" ] && [ -s "$PROOF_ONE" ] && proof_path_is_visual "$PROOF_ONE"; then
      continue
    fi
    BAD_PROOF="${BAD_PROOF}${BAD_PROOF:+, }$PROOF_ONE"
  done
  if [ -n "$BAD_PROOF" ]; then
    note proof fail "proof files missing, empty, or not screenshots/video: $BAD_PROOF; capture the running app under data/$ID/proof/ and report done again"
  else
    note proof pass "the ready report carries visual proof"
  fi
elif [ "$GIT_OK" != 1 ]; then
  note proof unknown "$GIT_WHY; cannot read whether the PR changes UI files"
else
  UI_CHANGED=
  while IFS= read -r pfile; do
    [ -n "$pfile" ] || continue
    pfile=$(printf '%s' "$pfile" | tr '[:upper:]' '[:lower:]')
    case "$pfile" in
      *.css|*.scss|*.sass|*.less|*.html|*.htm|*.tsx|*.jsx|*.vue|*.svelte|*.svg)
        UI_CHANGED="${UI_CHANGED}${UI_CHANGED:+, }$pfile" ;;
    esac
  done <<PROOF_FILES_EOF
$(git -C "$WT" diff --name-only "$BASE_REF...$HEAD" 2>/dev/null)
PROOF_FILES_EOF
  if [ -n "$UI_CHANGED" ]; then
    note proof fail "the PR changes UI files ($UI_CHANGED) but the ready report carries no proof rider; capture screenshots or a short video of the running app under data/$ID/proof/ and report done again with ' proof=<paths>' appended to the done line, or ' proof=none' when nothing user-visible changed"
  else
    note proof skip "no UI-facing files changed and no proof rider declared"
  fi
fi

# --- verdict --------------------------------------------------------------
FAILS=$(printf '%s' "$RESULTS" | awk -F'\t' '$2 == "fail" { printf "- %s: %s\n", $1, $3 }')
VERDICT=pass
[ -z "$FAILS" ] || VERDICT=fail

CHECKS_JSON=$(printf '%s' "$RESULTS" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], result: .[1], detail: .[2]})')
verdict_json() {  # <verdict> <action>
  jq -n -c --arg task "$ID" --arg pr "$URL" --arg head "$HEAD" --arg mode "$MODE" \
    --arg verdict "$1" --arg action "$2" --argjson checks "$CHECKS_JSON" --argjson at "$(date +%s)" \
    '{at: $at, task: $task, pr: $pr, head: $head, mode: $mode, verdict: $verdict, action: $action, checks: $checks}'
}
log_verdict() {  # <json>
  [ -d "$STATE" ] || return 0
  ( umask 077; printf '%s\n' "$1" >> "$STATE/done-check.log" ) 2>/dev/null || true
}
summary() {  # <action>
  printf 'done check [%s] %s on %s: %s\n' "$MODE" "$VERDICT" "$URL" "$1" >&2
  [ -z "$FAILS" ] || printf '%s\n' "$FAILS" >&2
}

if [ "$VERDICT" = pass ]; then
  JSON=$(verdict_json pass proceed)
  log_verdict "$JSON"
  printf '%s\n' "$JSON"
  summary proceed
  exit 0
fi

if [ "$MODE" = shadow ]; then
  JSON=$(verdict_json fail would-bounce)
  log_verdict "$JSON"
  printf '%s\n' "$JSON"
  summary "dry run, nothing sent"
  exit 0
fi

# --- on: bounce, bounded --------------------------------------------------
DC_STATE="$STATE/$ID.done-check"
BOUNCES=0
LAST_HEAD=
if [ -f "$DC_STATE" ] && [ ! -L "$DC_STATE" ]; then
  BOUNCES=$(grep '^bounces=' "$DC_STATE" | tail -1 | cut -d= -f2- || true)
  LAST_HEAD=$(grep '^last_head=' "$DC_STATE" | tail -1 | cut -d= -f2- || true)
  case "$BOUNCES" in ''|*[!0-9]*) BOUNCES=0 ;; esac
fi

if [ "$LAST_HEAD" = "$HEAD" ] && [ "$BOUNCES" -ge 1 ] && [ "$BOUNCES" -lt "$BOUNCE_LIMIT" ]; then
  JSON=$(verdict_json fail already-bounced)
  log_verdict "$JSON"
  printf '%s\n' "$JSON"
  summary "already steered the worker for this head; waiting for a new push"
  exit 10
fi

if [ "$BOUNCES" -ge "$BOUNCE_LIMIT" ]; then
  JSON=$(verdict_json fail escalate)
  log_verdict "$JSON"
  printf '%s\n' "$JSON"
  summary "bounce limit of $BOUNCE_LIMIT reached; firstmate must decide"
  exit 11
fi

NEXT=$((BOUNCES + 1))
MSG="Done checklist failed for $URL (head ${HEAD:0:8}); bounce $NEXT of $BOUNCE_LIMIT. Fix these, push, and report done again:
$FAILS"
if ! FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-send.sh" "$ID" "$MSG" >/dev/null 2>&1; then
  JSON=$(verdict_json fail steer-unconfirmed)
  log_verdict "$JSON"
  printf '%s\n' "$JSON"
  summary "the steer to the worker was not confirmed, so nothing was counted"
  exit 3
fi
( umask 077; printf 'bounces=%s\nlast_head=%s\n' "$NEXT" "$HEAD" > "$DC_STATE.tmp.$$" && mv -f -- "$DC_STATE.tmp.$$" "$DC_STATE" ) \
  || rm -f -- "$DC_STATE.tmp.$$"
JSON=$(verdict_json fail bounced)
log_verdict "$JSON"
printf '%s\n' "$JSON"
summary "steered the worker (bounce $NEXT of $BOUNCE_LIMIT)"
exit 10
