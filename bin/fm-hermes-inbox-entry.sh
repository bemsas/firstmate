#!/usr/bin/env bash
# fm-hermes-inbox-entry.sh - resolve the local checkout, then exec the bridge.
#
# Hermes installs this file as scripts/firstmate-inbox.sh inside the
# firstmate-inbox skill. When it lives in a scripts/ directory, pins in the
# skill root supply paths that were not passed in the environment:
#   firstmate-root  the checkout that contains bin/fm-hermes-inbox.sh
#   fm-home         the main firstmate home
# FM_FIRSTMATE_ROOT and FM_HOME override those pins.
# A pin must be one absolute path of letters, digits, and . _ + / -.
# A symlink pin is refused, and the pin text is never printed.
set -euo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
skill_dir=''
if [ "$(basename "$self_dir")" = scripts ]; then
  skill_dir=$(cd "$self_dir/.." && pwd)
fi
if [ -n "${FM_HERMES_SKILL_DIR:-}" ]; then
  case "$FM_HERMES_SKILL_DIR" in
    /*) skill_dir=$FM_HERMES_SKILL_DIR ;;
    *) printf '%s\n' 'error: FM_HERMES_SKILL_DIR must be an absolute path' >&2; exit 2 ;;
  esac
fi

read_pin() {  # <file>
  local file=$1 line
  if [ ! -e "$file" ]; then
    return 1
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf '%s\n' 'error: pin must be a regular file' >&2
    return 2
  fi
  line=$(awk 'NR==1 { line=$0 } NR>1 { exit 2 } END { if (NR==0) exit 3; printf "%s", line }' "$file") || {
    printf '%s\n' 'error: pin must be one absolute path' >&2
    return 2
  }
  case "$line" in
    /*) ;;
    *) printf '%s\n' 'error: pin must be one absolute path' >&2; return 2 ;;
  esac
  case "$line" in
    *[!A-Za-z0-9._+/-]*|*'/../'*|*'//'*|*/./*|*/..)
      printf '%s\n' 'error: pin must be one absolute path' >&2
      return 2
      ;;
  esac
  printf '%s' "$line"
}

resolve_pin() {  # <env-value> <pin-name>
  local value=$1 name=$2 pin_file pin rc=0
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi
  [ -n "$skill_dir" ] || {
    printf '%s\n' "error: $name is unset" >&2
    return 2
  }
  pin_file=$skill_dir/$name
  pin=$(read_pin "$pin_file") || rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s\n' "error: $name is unset" >&2
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  printf '%s' "$pin"
}

root=$(resolve_pin "${FM_FIRSTMATE_ROOT:-}" firstmate-root) || exit 2
home=$(resolve_pin "${FM_HOME:-}" fm-home) || exit 2
case "$root" in
  /*) ;;
  *) printf '%s\n' 'error: FM_FIRSTMATE_ROOT must be an absolute path' >&2; exit 2 ;;
esac
case "$home" in
  /*) ;;
  *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
esac
bridge=$root/bin/fm-hermes-inbox.sh
if [ ! -f "$bridge" ] || [ -L "$bridge" ]; then
  printf '%s\n' 'error: fm-hermes-inbox.sh is not in the resolved checkout' >&2
  exit 2
fi
export FM_HOME=$home
exec bash "$bridge" "$@"
