# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_QUOTA_LAUNCH_VERDICT is read by sourcing callers.
# fm-quota-launch-lib.sh - the single owner of the launch quota gate: which
# login a launch will spend on this host, the fresh quota-axi read of that
# login, and the only verdict that stops a launch.
#
# docs/configuration.md "Launch quota gate" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh before any endpoint or task record, including the
# launch half of a relaunch that goes through spawn, and by
# bin/fm-dispatch-resolve.sh for its intake snapshot.
#
# fm_quota_launch_gate <task> <harness> <model> <account-declared> <account-root> <raw 0|1> <backend>
#   <account-declared> and <account-root> are the first two fields of
#   fm_worker_account_select; both are empty for an unpinned launch, and an
#   `ordinary` Claude pin has an empty root.
#   Returns 1 only when a comparable reading of the matched login shows a scope
#   that bounds this model as exhausted_now or at 0% remaining. Every other
#   result returns 0: `ok` is silent, and `stale` (a missing tool, a failed,
#   slow, invalid, non-fresh, or unknown reading, a provider refresh time that
#   is missing, unbound, or outside the weekly window, or a login quota-axi
#   cannot be matched to) prints one line on stderr and leaves every other
#   launch protection in charge. Each call appends one line to
#   $STATE/quota-launch.log. Neither line carries an account name, a path, or
#   any quota-axi output. Nothing recorded is ever read back, so a later launch
#   or login change is judged only on its own fresh reading.
#
# fm_quota_launch_binding <harness> <model> <account-declared> <account-root> <raw 0|1> <backend>
#   Prints the exact selection one gate decision covers.
# fm_quota_launch_carry <decided-binding> <the gate's own seven arguments>
#   A relaunch asks the gate once, before it stops the running agent, and its
#   launch half calls this instead of reading again, so no later reading can
#   refuse after the stop. When the launch half selected exactly the decided
#   binding it is silent; any other selection is changed input that was not
#   read, reported as `stale reason=binding-changed`. Always returns 0.
#
# Only a login Firstmate itself selects for the worker can be matched. An
# unpinned worker takes its login from the destination terminal's environment,
# which this process cannot see, so no other login's usage may refuse it.
#
# Login selection (one read, bounded by FM_QUOTA_LAUNCH_SECONDS, default 15,
# with QUOTA_AXI_MAX_AGE and QUOTA_AXI_SNAPSHOT removed so nothing is reused,
# delegated credential refresh off, and `--full --json`, the only live tier
# that keeps each provider's state.refreshedAt):
#   claude          --provider claude --profile-only on the pinned or listed
#                   root, or $HOME/.claude for `ordinary`
#   pi, pi-signed   --provider codex under the pinned PI_CODING_AGENT_DIR, for
#                   an openai-codex* --model lane: the one row whose
#                   accountKeys contains that lane (accountKey on a row that
#                   publishes no accountKeys)
#   Unmatched, so always stale: every unpinned launch, every other harness, a
#   raw launch command, backend=t3code (T3 owns the account), a Pi lane that
#   quota-axi does not key (anything but openai-codex*), an `ordinary` Claude
#   pin with no HOME, and a Pi codex-native lane, whose Codex home the
#   terminal selects.
#
# A row is comparable only when it is labelled fresh, is flagged neither stale
# nor reused, and has its own timezone-bound state.refreshedAt inside the
# trailing weekly window. The snapshot's generatedAt is not that refresh time.
# Each scope that bounds the launch model is then judged on its own bounding
# windows (quota_scope_stale in bin/fm-quota-axi-lib.sh): one that cannot be
# shown current is stale, and leaves the other scopes comparable.
# Named provider and model choices stay preferences; this gate never selects
# a different login, family, or host.

FM_QUOTA_LAUNCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$FM_QUOTA_LAUNCH_LIB_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$FM_QUOTA_LAUNCH_LIB_DIR/fm-worker-account-lib.sh"

FM_QUOTA_LAUNCH_SECONDS=${FM_QUOTA_LAUNCH_SECONDS:-15}

# fm_quota_launch_report <task> <harness> <provider> <verdict> <detail>
fm_quota_launch_report() {
  local line="quota-gate: task=$1 harness=${2:--} provider=${3:--} quota=$4 $5"
  FM_QUOTA_LAUNCH_VERDICT=$4
  [ "$4" = ok ] || printf '%s\n' "$line" >&2
  [ -z "${STATE:-}" ] || [ ! -d "$STATE" ] ||
    { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$STATE/quota-launch.log"; } 2>/dev/null ||
    true
}

# fm_quota_launch_read <env-assignment>... -- <quota-axi args>...
# One bounded, non-reusing, non-refreshing full read. quota-axi exits nonzero
# for a provider it cannot measure yet still prints a snapshot naming that
# state, so the output, not the status, is judged. Returns 124 on a timeout,
# else 0 with whatever was printed. The vendor account identity and source
# attempts that --full adds are removed before anything else sees the output.
fm_quota_launch_read() {
  local -a read_env=(env -u QUOTA_AXI_MAX_AGE -u QUOTA_AXI_SNAPSHOT)
  local out rc=0
  while [ $# -gt 0 ] && [ "$1" != -- ]; do read_env+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  out=$(fm_run_timed "$FM_QUOTA_LAUNCH_SECONDS" "${read_env[@]}" \
    quota-axi "$@" --full --json --no-credential-refresh 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && fm_timed_out "$rc"; then
    return 124
  fi
  printf '%s\n' "$out" | jq -c 'if (.providers? | type) == "array"
    then .providers |= map(if type == "object" then del(.account, .attempts) else . end) else . end' 2>/dev/null ||
    printf '%s\n' "$out"
}

fm_quota_launch_binding() {
  local model=$2
  [ "$model" != default ] || model=
  printf '%s\037' "$1" "$model" "$3" "$4" "$5" "$6"
}

fm_quota_launch_carry() {
  local decided=$1
  shift
  [ "$(fm_quota_launch_binding "${@:2}")" = "$decided" ] ||
    fm_quota_launch_report "$1" "${2:--}" '' stale "reason=binding-changed"
  return 0
}

fm_quota_launch_gate() {
  local task=$1 harness=$2 model=$3 declared=$4 root=$5 raw=$6 backend=$7
  local provider='' lane='' bare snapshot verdict rc=0
  local -a read_env=() read_args=()
  [ "$model" != default ] || model=
  bare=${model##*/}

  if [ "$raw" = 1 ] || [ "$backend" = t3code ]; then
    fm_quota_launch_report "$task" "${harness:--}" '' stale "reason=unmatched-login"
    return 0
  fi
  case "$harness" in
    claude) provider=claude ;;
    pi | pi-signed)
      lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)' 2>/dev/null) || lane=
      case "$lane" in openai-codex | openai-codex-*) provider=codex ;; *) lane= ;; esac
      ;;
    *) provider=$(fm_quota_single_provider_for_harness "$harness") || provider= ;;
  esac
  if [ -n "$declared" ] && [ "$harness" = claude ] && { [ -n "$root" ] || [ -n "${HOME:-}" ]; }; then
    [ -n "$root" ] || root="$HOME/.claude"
    read_env=("CLAUDE_CONFIG_DIR=$root")
    read_args=(--provider claude --profile-only)
  elif [ -n "$declared" ] && [ -n "$root" ] && [ -n "$lane" ]; then
    read_env=("PI_CODING_AGENT_DIR=$root")
    read_args=(--provider codex)
  else
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=unmatched-login"
    return 0
  fi

  if ! command -v quota-axi >/dev/null 2>&1; then
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=quota-axi-missing"
    return 0
  fi
  snapshot=$(fm_quota_launch_read "${read_env[@]}" -- "${read_args[@]}") || rc=$?
  if [ "$rc" -eq 124 ]; then
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=read-timeout"
    return 0
  fi
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=read-failed"
    return 0
  fi
  # Prints "<verdict> <detail>"; every scope it names is one this program
  # matched against a fixed name or the launch's own model.
  verdict=$(printf '%s\n' "$snapshot" | jq -r --arg provider "$provider" --arg lane "$lane" \
    --arg model "$bare" "$FM_QUOTA_ROW_JQ"'
    . as $q |
    (if $lane == "" then quota_row($q; $provider; "")
     else [$q.providers[] | select(.provider == $provider) |
       select(quota_binds($lane) or ((.accountKeys? | type) != "array" and .accountKey? == $lane))] |
       if length == 1 then first else null end
     end) as $row |
    if $row == null then "stale reason=no-matching-row"
    elif quota_row_stale($row) then "stale reason=reading-not-fresh"
    else
      [$row.quotaSemantics.effectiveAvailability[] | select(
        .scope == "all_models" or .scope == "all_products" or
        ($model != "" and (.scope == ("model:" + $model) or .scope == ("product:" + $model))))] as $rows |
      [$rows[] | select(quota_scope_stale($row; .) | not)] as $current |
      ([$current[] | select(.runway.status? == "exhausted_now" or
          (.status == "known" and .effectivePercentRemaining <= 0))] | first) as $out |
      if $out != null then "exhausted scope=\($out.scope)"
      elif ($rows | length) == 0 then "stale reason=quota-unknown"
      elif ($current | length) < ($rows | length) then "stale reason=window-not-current"
      elif any($rows[]; .status != "known") then "stale reason=quota-unknown"
      else "ok reason=headroom"
      end
    end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict="stale reason=read-failed"
  fm_quota_launch_report "$task" "$harness" "$provider" "${verdict%% *}" "${verdict#* }"
  [ "${verdict%% *}" != exhausted ]
}

# fm_quota_launch_snapshot <config-dir>
# Prints one fresh, time-bounded, full quota-axi snapshot for dispatch intake,
# with account identity and source attempts removed, scoped to the logins this
# home's launches spend: a config/pi-account root answers the Pi rows, and a
# config/claude-account pin replaces the claude rows with that root's own. A
# config/pi-account that does not resolve drops every openai-codex* key from
# the rows, so no such Pi lane binds to an ambient login: a codex row left with
# no key is dropped, and a codex row published without accountKeys keeps only
# its native binding (its "default" or absent accountKey reads as codex-home).
# A Claude pin that cannot
# be read, or a config/claude-accounts list (the account is chosen later),
# leaves no claude row at all, so Claude reads as unmeasured instead of
# borrowing the ambient login's figures. Each such reason is left in
# FM_QUOTA_LAUNCH_SNAPSHOT_NOTES as "<scope>=<reason>" words, where the scope
# is claude, or pi-codex for the openai-codex* Pi lanes only, for the caller to
# report against the candidates it concerns, so call it without a command
# substitution. Returns 1 only when the read times out; a nonzero quota-axi
# status still prints its snapshot, and output validity is the caller's to
# check.
fm_quota_launch_snapshot() {
  local config=$1 listed selection declared root pinned='' snapshot pi_unusable=0
  local -a read_env=()
  FM_QUOTA_LAUNCH_SNAPSHOT_NOTES=
  if [ -e "$config/pi-account" ] || [ -L "$config/pi-account" ]; then
    selection=$(fm_worker_account_resolve pi "$config" config/pi-account 2>/dev/null) || selection=
    if [ -n "$selection" ]; then
      root=${selection#*$'\t'}
      read_env=("PI_CODING_AGENT_DIR=${root%%$'\t'*}")
    else
      pi_unusable=1
      FM_QUOTA_LAUNCH_SNAPSHOT_NOTES="pi-codex=pi-pin-unusable"
    fi
  fi
  snapshot=$(fm_quota_launch_read ${read_env[@]+"${read_env[@]}"} --) || return 1
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    printf '%s\n' "$snapshot"
    return 0
  fi
  if [ "$pi_unusable" = 1 ]; then
    snapshot=$(printf '%s\n' "$snapshot" | jq -c '
      def pi_key: type == "string" and test("^openai-codex(-|$)");
      .providers |= map(
        if (.accountKeys? | type) != "array" and .provider == "codex" then
          .accountKeys = [if .accountKey == null or .accountKey == "default" then "codex-home" else .accountKey end]
        else . end |
        if (.accountKeys? | type) == "array" and any(.accountKeys[]; pi_key)
        then .accountKeys |= map(select(pi_key | not)) |
          if (.accountKeys | length) == 0 then empty else . end
        else . end)') || return 1
  fi
  listed=$(fm_worker_account_list claude "$config" 2>/dev/null) || listed=unreadable
  if [ -z "$listed" ] && [ ! -e "$config/claude-account" ] && [ ! -L "$config/claude-account" ]; then
    printf '%s\n' "$snapshot"
    return 0
  fi
  if [ -z "$listed" ] &&
    selection=$(fm_worker_account_resolve claude "$config" config/claude-account 2>/dev/null) &&
    [ -n "$selection" ]; then
    declared=${selection%%$'\t'*}
    root=${selection#*$'\t'}
    root=${root%%$'\t'*}
    [ "$declared" != ordinary ] || root=${HOME:+$HOME/.claude}
    [ -z "$root" ] ||
      pinned=$(fm_quota_launch_read "CLAUDE_CONFIG_DIR=$root" -- --provider claude --profile-only) || pinned=
    printf '%s\n' "$pinned" | fm_quota_json_valid || pinned=
    [ -n "$pinned" ] ||
      FM_QUOTA_LAUNCH_SNAPSHOT_NOTES="${FM_QUOTA_LAUNCH_SNAPSHOT_NOTES:+$FM_QUOTA_LAUNCH_SNAPSHOT_NOTES }claude=pinned-read-failed"
  else
    local why=unmatched-login
    [ -n "$listed" ] || why=claude-pin-unusable
    FM_QUOTA_LAUNCH_SNAPSHOT_NOTES="${FM_QUOTA_LAUNCH_SNAPSHOT_NOTES:+$FM_QUOTA_LAUNCH_SNAPSHOT_NOTES }claude=$why"
  fi
  printf '%s\n' "$snapshot" | jq -c --argjson pinned "${pinned:-null}" '
    . as $all |
    [$pinned.providers[]? | select(.provider == "claude") |
      if $all.schemaVersion == 6 then .accountKey //= "default" else del(.accountKey) end] as $claude |
    .providers = [.providers[] | select(.provider != "claude")] + ($claude | .[0:(if $all.schemaVersion == 6 then length else 1 end)])
  '
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_quota_launch_gate "$@"
fi
