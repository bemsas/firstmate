# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_QUOTA_LAUNCH_VERDICT is read by sourcing callers.
# fm-quota-launch-lib.sh - the single owner of the launch quota gate: which
# login a launch will spend on this host, the fresh quota-axi read of that
# login, and the only verdict that stops a launch.
#
# docs/configuration.md "Launch quota gate" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh (every launch and relaunch, on the host that runs
# the agent) and bin/fm-control.sh (before a relaunch stops the live agent), by
# bin/fm-dispatch-resolve.sh for its intake snapshot, and by bin/fm-watch.sh to
# reread the login of a task parked on a rate limit.
#
# fm_quota_launch_gate <task> <harness> <model> <account-declared> <account-root> <raw 0|1> <backend>
#   <account-declared> and <account-root> are the first two fields of
#   fm_worker_account_select; both are empty for an unpinned launch, and an
#   `ordinary` Claude pin has an empty root.
#   Returns 1 only when a fresh reading of the matched login shows a scope that
#   bounds this model as exhausted_now or at 0% remaining. Every other result
#   returns 0: `ok` is silent, and `stale` (a missing tool, a failed, slow,
#   invalid, non-fresh, or unknown reading, or a login quota-axi cannot be
#   matched to) prints one line on stderr and leaves every other launch
#   protection in charge. Each call appends one line to
#   $STATE/quota-launch.log. Neither line carries an account name, a path, or
#   any quota-axi output. Nothing recorded is ever read back, so a later launch,
#   relaunch, or login change is judged only on its own fresh reading.
#
# Login selection (one read, bounded by FM_QUOTA_LAUNCH_SECONDS, default 15,
# with QUOTA_AXI_MAX_AGE and QUOTA_AXI_SNAPSHOT removed so nothing is reused,
# and with delegated credential refresh off):
#   claude          --profile-only on the pinned root, else for `ordinary`
#                   ~/.claude, else CLAUDE_CONFIG_DIR or ~/.claude
#   codex           --profile-only on ~/.codex
#   pi, pi-signed   the row whose accountKey equals the --model lane, read under
#                   the pinned PI_CODING_AGENT_DIR when there is one
#   grok, kimi, cursor, agy, muse
#                   that provider's row for this user
#   Unmatched, so always stale: every other harness, a raw launch command,
#   backend=t3code (T3 owns the account), an unpinned launch whose environment
#   carries a credential that outranks the stored login, and a non-default
#   CODEX_HOME or unpinned PI_CODING_AGENT_DIR, which the launch does not carry.

FM_QUOTA_LAUNCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$FM_QUOTA_LAUNCH_LIB_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$FM_QUOTA_LAUNCH_LIB_DIR/fm-worker-account-lib.sh"

FM_QUOTA_LAUNCH_SECONDS=${FM_QUOTA_LAUNCH_SECONDS:-15}

# fm_quota_launch_env_credential <harness>
# True when this environment carries a credential or provider switch that the
# runner would use instead of the stored login quota-axi measures.
fm_quota_launch_env_credential() {
  local names name
  case "$1" in
    claude) names=$FM_WORKER_ACCOUNT_CLAUDE_SHED ;;
    codex) names="OPENAI_API_KEY CODEX_API_KEY" ;;
    grok) names="XAI_API_KEY GROK_API_KEY" ;;
    kimi) names="KIMI_API_KEY MOONSHOT_API_KEY" ;;
    cursor) names="CURSOR_API_KEY" ;;
    agy) names="GEMINI_API_KEY GOOGLE_API_KEY" ;;
    muse) names="META_API_KEY MODEL_API_KEY" ;;
    *) return 1 ;;
  esac
  for name in $names; do
    [ -z "${!name:-}" ] || return 0
  done
  return 1
}

# fm_quota_launch_report <task> <harness> <provider> <verdict> <detail>
fm_quota_launch_report() {
  local line="quota-gate: task=$1 harness=$2 provider=${3:--} quota=$4 $5"
  FM_QUOTA_LAUNCH_VERDICT=$4
  [ "$4" = ok ] || printf '%s\n' "$line" >&2
  [ -z "${STATE:-}" ] || [ ! -d "$STATE" ] ||
    { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$STATE/quota-launch.log"; } 2>/dev/null ||
    true
}

fm_quota_launch_gate() {
  local task=$1 harness=$2 model=$3 declared=$4 root=$5 raw=$6 backend=$7
  local provider='' lane='' bare snapshot verdict
  local -a read_env=(env -u QUOTA_AXI_MAX_AGE -u QUOTA_AXI_SNAPSHOT) read_args=()
  [ "$model" != default ] || model=
  bare=${model##*/}

  if [ "$raw" = 1 ] || [ "$backend" = t3code ]; then
    fm_quota_launch_report "$task" "${harness:--}" '' stale "reason=unmatched-login"
    return 0
  fi
  case "$harness" in
    pi | pi-signed)
      lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)' 2>/dev/null) || lane=
      if [ -z "$lane" ]; then
        fm_quota_launch_report "$task" "$harness" '' stale "reason=unmatched-login"
        return 0
      fi
      # An unpinned worker takes its Pi root from the terminal's environment, so
      # a root named only in this process cannot be matched to it.
      if [ -z "$root" ] && [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
        fm_quota_launch_report "$task" "$harness" '' stale "reason=unmatched-login"
        return 0
      fi
      [ -z "$root" ] || read_env+=("PI_CODING_AGENT_DIR=$root")
      ;;
    *)
      provider=$(fm_quota_single_provider_for_harness "$harness") || {
        fm_quota_launch_report "$task" "$harness" '' stale "reason=unmatched-login"
        return 0
      }
      # The launch does not carry CODEX_HOME to the worker, so a non-default one
      # here cannot be matched to the login the worker will use.
      if { [ -z "$declared" ] && fm_quota_launch_env_credential "$harness"; } ||
        { [ "$harness" = codex ] && [ "${CODEX_HOME:-${HOME:-}/.codex}" != "${HOME:-}/.codex" ]; }; then
        fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=unmatched-login"
        return 0
      fi
      read_args=(--provider "$provider")
      case "$harness" in
        claude)
          if [ -z "$root" ]; then
            [ -n "$declared" ] || root=${CLAUDE_CONFIG_DIR:-}
            [ -n "$root" ] || root="${HOME:-}/.claude"
          fi
          read_env+=("CLAUDE_CONFIG_DIR=$root")
          read_args+=(--profile-only)
          ;;
        codex)
          lane=codex-home
          read_env+=("CODEX_HOME=${HOME:-}/.codex")
          read_args+=(--profile-only)
          ;;
      esac
      ;;
  esac

  if ! command -v quota-axi >/dev/null 2>&1; then
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=quota-axi-missing"
    return 0
  fi
  # quota-axi exits nonzero for a provider it cannot measure yet still prints a
  # snapshot naming that state, so the snapshot, not the status, is judged.
  snapshot=$(fm_run_timed "$FM_QUOTA_LAUNCH_SECONDS" "${read_env[@]}" \
    quota-axi ${read_args[@]+"${read_args[@]}"} --json --no-credential-refresh 2>/dev/null </dev/null) || {
    if fm_timed_out "$?"; then
      fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=read-timeout"
      return 0
    fi
  }
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    fm_quota_launch_report "$task" "$harness" "$provider" stale "reason=read-failed"
    return 0
  fi
  # Prints "<verdict> <detail>"; every scope it names is one this program
  # matched against a fixed name or the launch's own model.
  verdict=$(printf '%s\n' "$snapshot" | jq -r --arg provider "$provider" --arg lane "$lane" \
    --arg harness "$harness" --arg model "$bare" "$FM_QUOTA_ROW_JQ"'
    . as $q |
    (if $harness == "pi" or $harness == "pi-signed"
     then [$q.providers[] | select(.accountKey == $lane)] | if length == 1 then first else null end
     else quota_row($q; $provider; $lane) end) as $row |
    if $row == null then "stale reason=no-matching-row"
    elif ($row.state.status? != "fresh") or ($row.state.stale? == true) then "stale reason=reading-not-fresh"
    else
      $row.provider as $p |
      [$row.quotaSemantics.effectiveAvailability[] | select(
        .scope == "all_models" or .scope == "all_products" or
        ($model != "" and (.scope == ("model:" + $model) or .scope == ("product:" + $model))) or
        ($p == "agy" and
          ((.scope == "gemini" and ($model | startswith("gemini-"))) or
           (.scope == "claude_gpt" and ($model | startswith("claude-") or startswith("gpt-")))))
      )] as $rows |
      ([$rows[] | select(.runway.status? == "exhausted_now" or
          (.status == "known" and .effectivePercentRemaining <= 0))] | first) as $out |
      if $out != null then "exhausted scope=\($out.scope)"
      elif ($rows | length) == 0 or any($rows[]; .status != "known") then "stale reason=quota-unknown"
      else "ok reason=headroom"
      end
    end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict="stale reason=read-failed"
  fm_quota_launch_report "$task" "$harness" "$provider" "${verdict%% *}" "${verdict#* }"
  [ "${verdict%% *}" != exhausted ]
}

# fm_quota_launch_task_verdict <task> <meta-file> <config-dir>
# Sets FM_QUOTA_LAUNCH_VERDICT (ok, exhausted, or stale) from one fresh reading
# of the login a relaunch of this ship or scout record would select now: the
# recorded account under a declared list, else the home's current pin, else the
# ambient login. Informs the watcher's rate-limit report; it stops nothing.
fm_quota_launch_task_verdict() {
  local task=$1 meta=$2 config=$3 harness model backend listed account selection declared='' root=''
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  backend=$(fm_meta_get "$meta" backend)
  FM_QUOTA_LAUNCH_VERDICT=stale
  listed=$(fm_worker_account_list "$harness" "$config" 2>/dev/null) || return 0
  if [ -n "$listed" ]; then
    account=$(fm_meta_get "$meta" account)
    printf '%s\n' "$listed" | grep -qxF -- "$account" || return 0
    declared=$account
    [ "$account" = ordinary ] || root=$account
  else
    selection=$(fm_worker_account_resolve "$harness" "$config" "the $harness account pin" 2>/dev/null) || return 0
    if [ -n "$selection" ]; then
      declared=${selection%%$'\t'*}
      root=${selection#*$'\t'}
      root=${root%%$'\t'*}
    fi
  fi
  fm_quota_launch_gate "$task" "$harness" "$model" "$declared" "$root" 0 "${backend:-tmux}" 2>/dev/null || :
}

# fm_quota_launch_snapshot <config-dir>
# Prints one fresh, time-bounded quota-axi --json snapshot for dispatch intake, scoped to the
# logins this home's launches spend: a config/pi-account root answers the Pi
# rows, and a config/claude-account pin replaces the claude rows with that
# root's own. A pin that cannot be read, or a config/claude-accounts list (the
# account is chosen later), leaves no claude row at all, so Claude reads as
# unmeasured instead of borrowing the ambient login's figures. Returns 1 when
# the home's own read fails; output validity is the caller's to check.
fm_quota_launch_snapshot() {
  local config=$1 listed selection declared root pinned='' snapshot
  local -a read_env=(env -u QUOTA_AXI_MAX_AGE -u QUOTA_AXI_SNAPSHOT)
  selection=$(fm_worker_account_resolve pi "$config" config/pi-account 2>/dev/null) || selection=
  if [ -n "$selection" ]; then
    root=${selection#*$'\t'}
    read_env+=("PI_CODING_AGENT_DIR=${root%%$'\t'*}")
  fi
  snapshot=$(fm_run_timed "$FM_QUOTA_LAUNCH_SECONDS" "${read_env[@]}" quota-axi --json 2>/dev/null </dev/null) ||
    return 1
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
    [ "$declared" != ordinary ] || root="${HOME:-}/.claude"
    pinned=$(fm_run_timed "$FM_QUOTA_LAUNCH_SECONDS" env -u QUOTA_AXI_MAX_AGE -u QUOTA_AXI_SNAPSHOT \
      "CLAUDE_CONFIG_DIR=$root" quota-axi --provider claude --profile-only --json --no-credential-refresh \
      2>/dev/null </dev/null) || :
    printf '%s\n' "$pinned" | fm_quota_json_valid || pinned=
  fi
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    printf '%s\n' "$snapshot"
    return 0
  fi
  [ -n "$pinned" ] ||
    echo "quota-gate: provider=claude quota=stale reason=unmatched-login" >&2
  printf '%s\n' "$snapshot" | jq -c --argjson pinned "${pinned:-null}" '
    . as $all |
    [$pinned.providers[]? | select(.provider == "claude") |
      if $all.schemaVersion == 6 then .accountKey //= "default" else del(.accountKey) end] as $claude |
    .providers = [.providers[] | select(.provider != "claude")] + ($claude | .[0:(if $all.schemaVersion == 6 then length else 1 end)])
  '
}
