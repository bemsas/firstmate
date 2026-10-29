# shellcheck shell=bash
# Captain-status freshness helpers for the main supervision path.
# Usage: . bin/fm-captain-status-age-lib.sh
#
# data/secondbrain/status/captain-status.json carries the COO mate's rolling
# captain-facing summary. When its `updated` timestamp is older than
# FM_CAPTAIN_STATUS_MAX_AGE_SECS (default 45 minutes), main should surface a
# warning through bin/fm-guard.sh so firstmate can nudge a refresh.

_FM_CAPTAIN_STATUS_AGE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _FM_CAPTAIN_STATUS_AGE_LIB_DIR="."
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_CAPTAIN_STATUS_AGE_LIB_DIR/fm-classify-lib.sh"

FM_CAPTAIN_STATUS_MAX_AGE_SECS_DEFAULT=2700

fm_captain_status_age_file() {
  local home=${FM_HOME:-}
  local data=${FM_DATA_OVERRIDE:-${home:+$home/data}}
  [ -n "$data" ] || return 1
  printf '%s/secondbrain/status/captain-status.json\n' "$data"
}

# Print whole seconds since captain-status.json's `updated` field; return 1 when
# the file is absent or the timestamp cannot be read.
fm_captain_status_age_seconds() {
  local file updated now epoch age
  file=$(fm_captain_status_age_file) || return 1
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  updated=$(jq -r '.updated // empty' "$file" 2>/dev/null) || return 1
  [ -n "$updated" ] || return 1
  epoch=$(fm_utc_iso_to_epoch "$updated") || return 1
  now=$(date +%s)
  age=$((now - epoch))
  [ "$age" -ge 0 ] || return 1
  printf '%s\n' "$age"
}

# Return 0 when the file is present and older than the configured threshold.
fm_captain_status_is_stale() {
  local max=${FM_CAPTAIN_STATUS_MAX_AGE_SECS:-$FM_CAPTAIN_STATUS_MAX_AGE_SECS_DEFAULT} age
  case "$max" in ''|*[!0-9]*) max=$FM_CAPTAIN_STATUS_MAX_AGE_SECS_DEFAULT ;; esac
  age=$(fm_captain_status_age_seconds) || return 1
  [ "$age" -gt "$max" ]
}

# Print a one-line operator warning to stderr when stale; always exit 0.
fm_captain_status_age_warn() {
  local file updated max=${FM_CAPTAIN_STATUS_MAX_AGE_SECS:-$FM_CAPTAIN_STATUS_MAX_AGE_SECS_DEFAULT} age minutes
  fm_captain_status_is_stale || return 0
  file=$(fm_captain_status_age_file) || return 0
  updated=$(jq -r '.updated // empty' "$file" 2>/dev/null) || updated='(unknown)'
  age=$(fm_captain_status_age_seconds) || return 0
  minutes=$(( (age + 59) / 60 ))
  case "$max" in ''|*[!0-9]*) max=$FM_CAPTAIN_STATUS_MAX_AGE_SECS_DEFAULT ;; esac
  printf 'WARNING: captain-status.json is %s minutes old (updated %s; threshold %s minutes).\n' \
    "$minutes" "$updated" "$((max / 60))" >&2
  return 0
}
