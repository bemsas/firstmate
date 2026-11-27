# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns an absent binary into the operator-facing MISSING diagnostic and an
# incompatible installed build into OUTDATED, which keeps an older build from
# reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.51
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row_stale($row)          true when the row's own reading is not
#                                  comparable: no state object, a non-fresh
#                                  status, the stale or reused flag, or an unusable
#                                  state.refreshedAt (missing, unbound,
#                                  unreadable, in the future, or older than the
#                                  trailing weekly window). Snapshot generatedAt
#                                  is a different clock and is never consulted.
#                                  Only `--full --json` (or a reused reading)
#                                  carries state.refreshedAt; a lean live
#                                  `--json` row omits it and reads as stale.
#   quota_scope_stale($row; $ea)   true when the windows bounding that one
#                                  effectiveAvailability entry (its boundedBy
#                                  and limitingWindowIds, else every window
#                                  the row reports) cannot be shown current:
#                                  a named window the row does not report; a
#                                  reset that is past or unreadable; a start
#                                  that is unreadable or after the row's
#                                  refresh time; a resetless window whose own
#                                  length (windowSeconds, else its session,
#                                  weekly, or monthly kind) has elapsed since
#                                  its start, else since the refresh; or a
#                                  resetless window of unknown length, or no
#                                  window at all, on a reading older than the
#                                  live age bound (fifteen minutes). Other
#                                  scopes stay comparable.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null. With a lane and rows that publish
#                                  accountKeys (every quota-axi schema 5 and 6
#                                  row), it is the single row whose accountKeys
#                                  contains the lane, else null. Without
#                                  accountKeys, schema 6 matches accountKey and
#                                  then "default", and schema 5 takes the row.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
# The refresh horizon is seven days (the weekly window) plus two minutes of
# future clock skew. A labelled-fresh row older than that is not evidence of
# the current window, even when the aggregate snapshot was just generated.
FM_QUOTA_ROW_JQ='
  def quota_epoch:
    capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $m |
    (($m.t + "Z") | fromdateiso8601) -
      (if $m.z == "Z" then 0
       else (if $m.z[0:1] == "-" then -1 else 1 end) *
         (($m.z[1:3] | tonumber) * 3600 + ($m.z[4:6] | tonumber) * 60)
       end);
  def quota_refresh_horizon: 604800;
  def quota_refresh_skew: 120;
  def quota_live_age: 900;
  def quota_refresh_epoch($row):
    ($row.state.refreshedAt? | if type == "string" and . != "" then . else null end) as $t |
    if $t == null then null
    else ((try ($t | quota_epoch) catch null) // null)
    end;
  def quota_refresh_unusable($row):
    quota_refresh_epoch($row) as $e |
    $e == null or $e > (now + quota_refresh_skew) or $e < (now - quota_refresh_horizon);
  def quota_row_stale($row):
    (($row.state? | type) != "object") or
    ($row.state.status? != "fresh") or
    ($row.state.stale? == true) or
    ($row.state.reused? == true) or
    quota_refresh_unusable($row);
  def quota_time: (try quota_epoch catch null) // null;
  def quota_window_seconds:
    if (.windowSeconds? | type) == "number" and .windowSeconds > 0 then .windowSeconds
    elif .kind? == "session" then 18000
    elif .kind? == "weekly" then 604800
    elif .kind? == "monthly" then 2419200
    else null
    end;
  def quota_past_live_age($refreshed): $refreshed < (now - quota_live_age);
  def quota_window_stale($refreshed):
    (if .startsAt? == null then $refreshed else (.startsAt | quota_time) end) as $start |
    if $start == null or $start > $refreshed then true
    elif .resetsAt? != null then ((.resetsAt | quota_time) // 0) <= now
    else quota_window_seconds as $length |
      if $length == null then quota_past_live_age($refreshed) else ($start + $length) <= now end
    end;
  def quota_scope_stale($row; $ea):
    ([($ea.boundedBy? // [])[]?, ($ea.limitingWindowIds? // [])[]?] | map(select(type == "string"))) as $ids |
    (quota_refresh_epoch($row) // 0) as $refreshed |
    [$row.windows[]? | select(type == "object")] as $windows |
    [$windows[] | select(($ids | length) == 0 or (.id as $id | any($ids[]; . == $id)))] as $bounding |
    any($ids[]; . as $id | any($windows[]; .id == $id) | not) or
    (if ($bounding | length) == 0 then quota_past_live_age($refreshed)
     else any($bounding[]; quota_window_stale($refreshed))
     end);
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_binds($lane):
    (.accountKeys? | type) == "array" and any(.accountKeys[]; . == $lane);
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $lane != "" and any($rows[]; (.accountKeys? | type) == "array") then
      ([$rows[] | select(quota_binds($lane))] | if length == 1 then first else null end)
    elif $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

# fm_quota_axi_version_compatible <version-output>
# True when the printed `quota-axi --version` text meets FM_QUOTA_AXI_MIN.
# Callers that already captured a bounded --version pass that text here so they
# do not launch a second, unbounded version probe.
fm_quota_axi_version_compatible() {
  local output=${1-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  fm_quota_axi_version_compatible "$output"
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

# Reads the whole table before answering: leaving the loop early closes the
# pipe mid-write, and where SIGPIPE is ignored the writer prints a broken-pipe
# error on stderr.
fm_quota_single_provider_for_harness() {
  local harness provider found=''
  while read -r harness provider; do
    [ -z "$found" ] && [ "$harness" = "$1" ] && found=$provider || :
  done < <(fm_quota_single_provider_table)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}
