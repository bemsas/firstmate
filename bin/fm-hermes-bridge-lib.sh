#!/usr/bin/env bash
# fm-hermes-bridge-lib.sh - private exchange log for the Hermes and Grokbot ask scripts.
#
# Sourced, never executed. bin/fm-ask-hermes.sh, bin/fm-ask-grokbot.sh, and
# bin/fm-hermes-inbox.sh own their flags. This file owns the log row and the
# private append.
#
# Log path: $FM_HOME/data/hermes-bridge/log.jsonl
# Directory mode 0700, file mode 0600. Appends serialize on a mkdir lock.
# One JSON object per line:
#   timestamp, exchange_id, correlation_id, target, topic, profile,
#   direction, outcome, exit_code, request, reply, version
# request and reply are bounded text, or sha256:<hex> when the text matches
# api_key, token, secret, password, Bearer, or a shell assignment line.
# version is empty except when a caller has a provider version to record.
# The log never receives an environment dump.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf '%s\n' 'fm-hermes-bridge-lib.sh is sourced, not executed' >&2
  exit 2
fi

FM_HERMES_BRIDGE_MAX_BYTES=100000

fm_hermes_bridge_dir() {
  printf '%s/data/hermes-bridge' "${FM_HOME:?}"
}

fm_hermes_bridge_log_path() {
  printf '%s/log.jsonl' "$(fm_hermes_bridge_dir)"
}

fm_hermes_bridge_corr_ok() {  # <id>
  case "$1" in
    [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      return 0
      ;;
  esac
  return 1
}

fm_hermes_bridge_profile_for_topic() {  # <topic>
  case "$1" in
    admin) printf '%s\n' desktop ;;
    ops) printf '%s\n' ops ;;
    trix) printf '%s\n' trix ;;
    *) return 1 ;;
  esac
}

fm_hermes_bridge_topic_for_profile() {  # <profile>
  case "$1" in
    desktop) printf '%s\n' admin ;;
    ops) printf '%s\n' ops ;;
    trix) printf '%s\n' trix ;;
    *) return 1 ;;
  esac
}

fm_hermes_bridge_new_id() {
  local raw
  raw=$(openssl rand -hex 8 2>/dev/null || true)
  raw=$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9')
  if [ "${#raw}" -ne 16 ]; then
    raw=$(printf '%s' "$$-${RANDOM}${RANDOM}-$(date +%s)" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
  fi
  [ "${#raw}" -eq 16 ] || return 1
  printf '%s' "$raw"
}

fm_hermes_bridge_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

fm_hermes_bridge_prepare_dir() {
  local dir
  dir=$(fm_hermes_bridge_dir)
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1
}

fm_hermes_bridge_lock_acquire() {
  local dir lock now mtime age i=0
  fm_hermes_bridge_prepare_dir || return 1
  dir=$(fm_hermes_bridge_dir)
  lock="$dir/.append.lock"
  while true; do
    if mkdir "$lock" 2>/dev/null; then
      return 0
    fi
    now=$(date +%s)
    mtime=$(fm_hermes_bridge_mtime "$lock" || printf '%s' "$now")
    age=$((now - mtime))
    if [ "$age" -gt 60 ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    i=$((i + 1))
    [ "$i" -lt 100 ] || return 1
    sleep 0.1
  done
}

fm_hermes_bridge_lock_release() {
  rmdir "$(fm_hermes_bridge_dir)/.append.lock" 2>/dev/null || true
}

fm_hermes_bridge_unsafe() {  # <text> -> 0 when the text must be hashed
  printf '%s' "$1" | LC_ALL=C grep -q -i -E -e 'api[_-]?key' -e 'token' -e 'secret' -e 'password' -e 'bearer' -e '^[A-Za-z_][A-Za-z0-9_]*='
}

fm_hermes_bridge_hash() {  # <text>
  local hex=''
  hex=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}') || true
  if [ -z "$hex" ]; then
    hex=$(printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}') || true
  fi
  case "$hex" in
    [0-9a-f]*[0-9a-f]) printf '%s' "$hex" ;;
    *) return 1 ;;
  esac
}

fm_hermes_bridge_json_escape() {  # <text>
  local s=$1
  s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013-\037\177')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

fm_hermes_bridge_log_value() {  # <text> -> JSON string content, no quotes
  local text=$1 hex bound
  if fm_hermes_bridge_unsafe "$text"; then
    hex=$(fm_hermes_bridge_hash "$text") || return 1
    printf 'sha256:%s' "$hex"
    return 0
  fi
  bound=$(printf '%s' "$text" | head -c 400)
  fm_hermes_bridge_json_escape "$bound"
}

fm_hermes_bridge_log_exchange() {  # target exchange corr topic profile direction outcome code request reply version
  local target=$1 exchange=$2 corr=$3 topic=$4 profile=$5 direction=$6 outcome=$7 code=$8 request=$9
  local reply=${10-} version=${11-} path json req rep ts
  case "$code" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  req=$(fm_hermes_bridge_log_value "$request") || return 1
  rep=$(fm_hermes_bridge_log_value "$reply") || return 1
  json=$(printf '{"timestamp":"%s","exchange_id":"%s","correlation_id":"%s","target":"%s","topic":"%s","profile":"%s","direction":"%s","outcome":"%s","exit_code":%s,"request":"%s","reply":"%s","version":"%s"}' \
    "$(fm_hermes_bridge_json_escape "$ts")" \
    "$(fm_hermes_bridge_json_escape "$exchange")" \
    "$(fm_hermes_bridge_json_escape "$corr")" \
    "$(fm_hermes_bridge_json_escape "$target")" \
    "$(fm_hermes_bridge_json_escape "$topic")" \
    "$(fm_hermes_bridge_json_escape "$profile")" \
    "$(fm_hermes_bridge_json_escape "$direction")" \
    "$(fm_hermes_bridge_json_escape "$outcome")" \
    "$code" \
    "$req" \
    "$rep" \
    "$(fm_hermes_bridge_json_escape "$version")")
  fm_hermes_bridge_lock_acquire || return 1
  path=$(fm_hermes_bridge_log_path)
  umask 077
  if ! touch "$path"; then
    fm_hermes_bridge_lock_release
    return 1
  fi
  if ! chmod 600 "$path"; then
    fm_hermes_bridge_lock_release
    return 1
  fi
  if ! printf '%s\n' "$json" >> "$path"; then
    fm_hermes_bridge_lock_release
    return 1
  fi
  fm_hermes_bridge_lock_release
}

# Read a message body from a regular file, or from stdin when <path> is empty.
# Prints the body. Return 2 bad file, 3 too large, 4 empty, 5 NUL, 1 IO error.
fm_hermes_bridge_read_body() {  # [path]
  local path=${1-} tmp bytes max=$FM_HERMES_BRIDGE_MAX_BYTES
  tmp=$(mktemp) || return 1
  if [ -n "$path" ]; then
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      rm -f "$tmp"
      return 2
    fi
    if ! head -c "$((max + 1))" "$path" > "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  elif ! head -c "$((max + 1))" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  bytes=$(wc -c < "$tmp" | tr -d ' ')
  if [ "$bytes" -gt "$max" ]; then
    rm -f "$tmp"
    return 3
  fi
  if [ "$bytes" -eq 0 ]; then
    rm -f "$tmp"
    return 4
  fi
  if ! cmp -s "$tmp" <(LC_ALL=C tr -d '\0' < "$tmp"); then
    rm -f "$tmp"
    return 5
  fi
  cat "$tmp"
  rm -f "$tmp"
}
