#!/usr/bin/env bash
# fm-hermes-digest-lib.sh - format one captain digest from captain-status.v1.
#
# Sourced, never executed. bin/fm-hermes-daily-digest.sh owns delivery.
# The source is the main home's read-only
# data/secondbrain/status/captain-status.json. This file owns how that
# snapshot becomes text.
#
# Resolution order for the source file:
#   1. FM_HERMES_DIGEST_SOURCE, when set
#   2. $FM_HOME/config/hermes-digest-source, when that regular file exists
# A value is either an absolute local path or ssh://host/absolute/path.
# ssh:// is read with BatchMode and a bounded timeout. The remote command
# is cat of that one path. FM_HERMES_DIGEST_SSH_BIN replaces ssh in tests.
# A local parent home (parent_home= in .fm-secondmate-parent) is used when
# no explicit source is set, at
# $parent_home/data/secondbrain/status/captain-status.json.
# A home that is not a secondmate uses the same path under $FM_HOME.
# A remote parent without an explicit source fails closed.
# The resolver never searches a home tree and never reads .env, token,
# auth, credential, or MCP token files.
#
# captain-status.v1 fields used here:
#   schema, updated, headline, waiting_on_you[{what,why}],
#   done_recently[string], projects[{where,next,running[]}]
# Optional blockers[] are strings or {what,why}. When blockers is absent,
# a project line is a blocker only when it contains the whole word blocked.
# waiting_on_you items are the open captain decisions.
# A merge is a done_recently string that contains a recorded timestamp
# inside the 24 hours ending at the supplied instant. An ISO-8601 UTC
# stamp wins. Otherwise the first "D Month" or "D Month YYYY" date wins,
# with an optional "at HH:MM:SSZ". A clock time with no date is not a
# timestamp. Undated lines are not merges.
# updated more than 36 hours before the supplied instant is stale.
# The same snapshot and the same instant always format the same text.
# Each group keeps source order and at most five items. A full https://
# URL in an included item is copied unchanged. Empty groups say None.
# The first line is one concrete action: the first decision, otherwise
# the headline, otherwise a line that nothing is waiting.
#
# FM_HERMES_DIGEST_STALE_SECONDS overrides the 36-hour bound in tests.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf '%s\n' 'fm-hermes-digest-lib.sh is sourced, not executed' >&2
  exit 2
fi

FM_HERMES_DIGEST_STALE_DEFAULT=129600

fm_hermes_digest_die() {
  printf 'error: %s\n' "$1" >&2
  return 2
}

fm_hermes_digest_epoch_of_iso() {  # <YYYY-MM-DDTHH:MM:SSZ>
  local iso=$1 epoch=''
  case "$iso" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)
  if [ -z "$epoch" ]; then
    epoch=$(date -u -d "$iso" +%s 2>/dev/null || true)
  fi
  case "$epoch" in
    [0-9]*) printf '%s' "$epoch" ;;
    *) return 1 ;;
  esac
}

fm_hermes_digest_london_date() {  # <epoch>
  local epoch=$1 day=''
  day=$(TZ=Europe/London date -r "$epoch" +%F 2>/dev/null || true)
  if [ -z "$day" ]; then
    day=$(TZ=Europe/London date -d "@$epoch" +%F 2>/dev/null || true)
  fi
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s' "$day" ;;
    *) return 1 ;;
  esac
}

fm_hermes_digest_utc_year() {  # <epoch>
  local epoch=$1 year=''
  year=$(date -u -r "$epoch" +%Y 2>/dev/null || true)
  if [ -z "$year" ]; then
    year=$(date -u -d "@$epoch" +%Y 2>/dev/null || true)
  fi
  case "$year" in
    [0-9][0-9][0-9][0-9]) printf '%s' "$year" ;;
    *) return 1 ;;
  esac
}

fm_hermes_digest_month_num() {  # <English-month>
  case "$1" in
    January) printf '1' ;;
    February) printf '2' ;;
    March) printf '3' ;;
    April) printf '4' ;;
    May) printf '5' ;;
    June) printf '6' ;;
    July) printf '7' ;;
    August) printf '8' ;;
    September) printf '9' ;;
    October) printf '10' ;;
    November) printf '11' ;;
    December) printf '12' ;;
    *) return 1 ;;
  esac
}

fm_hermes_digest_forbidden_source() {  # <path>
  local base
  base=$(basename "$1")
  case "$base" in
    .env|auth.json|*.env|*token*|*secret*|credentials*) return 0 ;;
  esac
  return 1
}

fm_hermes_digest_source_spec() {  # prints the configured spec, or empty
  local home=${FM_HOME:-} spec='' cfg
  if [ -n "${FM_HERMES_DIGEST_SOURCE:-}" ]; then
    printf '%s' "$FM_HERMES_DIGEST_SOURCE"
    return 0
  fi
  case "$home" in
    /*) ;;
    *) return 0 ;;
  esac
  cfg=$home/config/hermes-digest-source
  if [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
    spec=$(head -n 1 "$cfg" | tr -d '\r')
    printf '%s' "$spec"
  fi
}

fm_hermes_digest_local_default() {  # prints a local path or nothing
  local home parent route parent_home line
  home=${FM_HOME:-}
  parent=$home/.fm-secondmate-parent
  route=
  parent_home=
  [ -n "$home" ] || return 0
  if [ -f "$home/.fm-secondmate-home" ]; then
    [ -f "$parent" ] && [ ! -L "$parent" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        route=*) route=${line#route=} ;;
        parent_home=*) parent_home=${line#parent_home=} ;;
      esac
    done < "$parent"
    if [ "$route" = local ] && [ -n "$parent_home" ]; then
      printf '%s/data/secondbrain/status/captain-status.json' "$parent_home"
    fi
    return 0
  fi
  printf '%s/data/secondbrain/status/captain-status.json' "$home"
}

fm_hermes_digest_materialize() {  # <spec> -> prints a local regular-file path
  local spec=$1 host path ssh_bin tmp rc=0
  FM_HERMES_DIGEST_TEMP=${FM_HERMES_DIGEST_TEMP:-}
  case "$spec" in
    ssh://*)
      host=${spec#ssh://}
      host=${host%%/*}
      path=/${spec#ssh://*/}
      case "$host" in
        ''|*[!A-Za-z0-9._-]*) fm_hermes_digest_die "captain-status ssh host is not a plain hostname"; return ;;
      esac
      case "$path" in
        /*) ;;
        *) fm_hermes_digest_die "captain-status ssh path must be absolute"; return ;;
      esac
      case "$path" in
        *'..'*|*' '*|*'"'*|*\'*|*'$'*|*'`'*)
          fm_hermes_digest_die "captain-status ssh path is not a single absolute path"
          return
          ;;
      esac
      fm_hermes_digest_forbidden_source "$path" && {
        fm_hermes_digest_die "captain-status path is a credential file"
        return
      }
      ssh_bin=${FM_HERMES_DIGEST_SSH_BIN:-ssh}
      tmp=$(mktemp) || return 1
      FM_HERMES_DIGEST_TEMP=$tmp
      set +e
      fm_run_timed 20 "$ssh_bin" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o ClearAllForwardings=yes \
        "$host" \
        cat -- "$path" > "$tmp"
      rc=$?
      set -e
      if fm_timed_out "$rc" || [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        FM_HERMES_DIGEST_TEMP=''
        fm_hermes_digest_die "captain-status could not be read from $spec"
        return
      fi
      printf '%s' "$tmp"
      ;;
    /*)
      fm_hermes_digest_forbidden_source "$spec" && {
        fm_hermes_digest_die "captain-status path is a credential file"
        return
      }
      printf '%s' "$spec"
      ;;
    '')
      fm_hermes_digest_die "captain-status source is not configured"
      return
      ;;
    *)
      fm_hermes_digest_die "captain-status source must be an absolute path or ssh://host/absolute/path"
      return
      ;;
  esac
}

fm_hermes_digest_prepare_file() {  # <path>
  local path=$1 bytes
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    fm_hermes_digest_die "captain-status is absent or not a regular file: $path"
    return
  fi
  bytes=$(wc -c < "$path" | tr -d ' ')
  if [ "$bytes" -gt 200000 ]; then
    fm_hermes_digest_die "captain-status exceeds the size bound"
    return
  fi
  if ! cmp -s "$path" <(LC_ALL=C tr -d '\0' < "$path"); then
    fm_hermes_digest_die "captain-status contains a NUL byte"
    return
  fi
}

fm_hermes_digest_merge_epoch() {  # <text> <now>
  local text=$1 now=$2 iso='' day month year time mon epoch
  iso=$(printf '%s' "$text" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | head -n 1 || true)
  if [ -n "$iso" ]; then
    fm_hermes_digest_epoch_of_iso "$iso" || true
    return 0
  fi
  if [[ $text =~ ([0-9]{1,2})[[:space:]](January|February|March|April|May|June|July|August|September|October|November|December)([[:space:]]([0-9]{4}))?([[:space:]]at[[:space:]]([0-9]{2}:[0-9]{2}:[0-9]{2})Z)? ]]; then
    day=${BASH_REMATCH[1]}
    month=${BASH_REMATCH[2]}
    year=${BASH_REMATCH[4]}
    time=${BASH_REMATCH[6]}
    if [ -z "$year" ]; then
      year=$(fm_hermes_digest_utc_year "$now") || return 0
    fi
    [ -n "$time" ] || time=00:00:00
    mon=$(fm_hermes_digest_month_num "$month") || return 0
    printf -v iso '%04d-%02d-%02dT%sZ' "$year" "$mon" "$day" "$time"
    epoch=$(fm_hermes_digest_epoch_of_iso "$iso" || true)
    if [ -n "$epoch" ] && [ "$epoch" -gt $((now + 86400)) ]; then
      year=$((year - 1))
      printf -v iso '%04d-%02d-%02dT%sZ' "$year" "$mon" "$day" "$time"
      epoch=$(fm_hermes_digest_epoch_of_iso "$iso" || true)
    fi
    [ -n "$epoch" ] && printf '%s' "$epoch"
  fi
}

fm_hermes_digest_append_group() {  # <title> <item-file> <dest>
  local title=$1 items=$2 dest=$3 count=0 extra=0 line
  printf '\n%s\n' "$title" >> "$dest"
  if [ ! -s "$items" ]; then
    printf '%s\n' '- None.' >> "$dest"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    if [ "$count" -le 5 ]; then
      printf -- '- %s\n' "$line" >> "$dest"
    else
      extra=$((extra + 1))
    fi
  done < "$items"
  if [ "$extra" -gt 0 ]; then
    printf 'And %s more.\n' "$extra" >> "$dest"
  fi
}

fm_hermes_digest_format() {  # <json-path> <now-epoch>
  local json=$1 now=$2 updated updated_epoch stale headline action
  local work line epoch start why
  command -v jq >/dev/null 2>&1 || { fm_hermes_digest_die "jq is required"; return; }
  case "$now" in
    [0-9]*) ;;
    *) fm_hermes_digest_die "digest instant must be a Unix epoch"; return ;;
  esac
  fm_hermes_digest_prepare_file "$json" || return
  if ! jq -e '
    .schema == "captain-status.v1"
    and (.updated | type == "string")
    and (.headline | type == "string")
    and (.waiting_on_you | type == "array")
    and (.done_recently | type == "array")
    and (.projects | type == "array")
    and all(.waiting_on_you[]; type == "object" and (.what | type == "string") and (.why | type == "string"))
    and all(.done_recently[]; type == "string")
    and all(.projects[]; type == "object" and (.where | type == "string") and (.next | type == "string") and (.running | type == "array") and all(.running[]; type == "string"))
    and ((.blockers | type) == "null" or (.blockers | type) == "array")
  ' "$json" >/dev/null; then
    fm_hermes_digest_die "captain-status is malformed"
    return
  fi
  updated=$(jq -r '.updated' "$json")
  updated_epoch=$(fm_hermes_digest_epoch_of_iso "$updated" || true)
  if [ -z "$updated_epoch" ]; then
    fm_hermes_digest_die "captain-status updated time is malformed"
    return
  fi
  stale=${FM_HERMES_DIGEST_STALE_SECONDS:-$FM_HERMES_DIGEST_STALE_DEFAULT}
  if [ $((now - updated_epoch)) -gt "$stale" ] || [ "$updated_epoch" -gt $((now + 300)) ]; then
    fm_hermes_digest_die "captain-status is stale: updated $updated"
    return
  fi
  work=$(mktemp -d) || return 1
  jq -r '.waiting_on_you[] | .what + "\t" + .why' "$json" > "$work/decisions.tsv"
  : > "$work/decisions"
  while IFS=$(printf '\t') read -r action why || [ -n "${action:-}" ]; do
    [ -n "${action:-}" ] || continue
    if [ -n "$why" ]; then
      printf '%s. %s\n' "$action" "$why" >> "$work/decisions"
    else
      printf '%s\n' "$action" >> "$work/decisions"
    fi
  done < "$work/decisions.tsv"
  : > "$work/blockers"
  if jq -e '.blockers | type == "array"' "$json" >/dev/null; then
    jq -r '.blockers[] | if type == "string" then . elif type == "object" and (.what | type == "string") then .what + (if (.why | type) == "string" and .why != "" then ". " + .why else "" end) else empty end' "$json" > "$work/blockers"
  else
    jq -r '.projects[] | .where, .next, .running[]' "$json" | while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if printf '%s' "$line" | grep -E -q '(^|[^[:alpha:]])blocked([^[:alpha:]]|$)'; then
        printf '%s\n' "$line" >> "$work/blockers"
      fi
    done
  fi
  : > "$work/merges"
  start=$((now - 86400))
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    epoch=$(fm_hermes_digest_merge_epoch "$line" "$now" || true)
    [ -n "$epoch" ] || continue
    if [ "$epoch" -ge "$start" ] && [ "$epoch" -le "$now" ]; then
      printf '%s\n' "$line" >> "$work/merges"
    fi
  done < <(jq -r '.done_recently[]' "$json")
  headline=$(jq -r '.headline' "$json")
  action=$(head -n 1 "$work/decisions.tsv" | cut -f 1)
  if [ -z "$action" ]; then
    action=$headline
  fi
  if [ -z "$action" ]; then
    action='nothing is waiting on you'
  fi
  : > "$work/out"
  printf 'Do this: %s\n' "$action" >> "$work/out"
  fm_hermes_digest_append_group 'Decisions' "$work/decisions" "$work/out"
  fm_hermes_digest_append_group 'Blockers' "$work/blockers" "$work/out"
  fm_hermes_digest_append_group 'Merges in the last 24 hours' "$work/merges" "$work/out"
  cat "$work/out"
  rm -rf "$work"
}
