#!/usr/bin/env bash
# fm-hermes-skill-install.sh - write the firstmate-inbox skill into one Hermes skills directory.
#
# install writes <skills-dir>/firstmate-inbox/ with:
#   SKILL.md                     copied from hermes/firstmate-inbox/SKILL.md
#   scripts/firstmate-inbox.sh   copied from bin/fm-hermes-inbox-entry.sh
#   firstmate-root               pin: this checkout
#   fm-home                      pin: FM_HOME, the home whose inbox receives notes
# The pins follow the rule bin/fm-hermes-inbox-entry.sh enforces, and a path
# that rule would refuse is refused here before anything is written.
# A Hermes profile's skills directory is <profile-home>/skills, for example
# ~/.hermes/profiles/desktop/skills. Install once per profile that posts.
# Any directory under $HOME/.hermes is refused unless
# FM_HERMES_SKILL_ALLOW_LIVE=1. Firstmate sets that only when installing
# after the local branch has landed.
# This command never runs hermes and never restarts a gateway.
#
# Exit codes:
#   0  installed
#   2  usage, a bad path, or a refused live directory
#   1  a write failed
#
# Usage:
#   fm-hermes-skill-install.sh install --skills-dir <absolute-dir>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

umask 022

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-hermes-skill-install.sh install --skills-dir <absolute-dir>
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Write the firstmate-inbox skill into one Hermes skills directory.

The skill gets SKILL.md, scripts/firstmate-inbox.sh, and two pins:
firstmate-root is this checkout and fm-home is FM_HOME.
A directory under ~/.hermes needs FM_HERMES_SKILL_ALLOW_LIVE=1.
This command never runs hermes and never restarts a gateway.
EOF
}

pin_ok() {  # <path> - the same rule fm-hermes-inbox-entry.sh applies
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._+/-]*|*'/../'*|*'//'*|*/./*|*/..) return 1 ;;
  esac
  return 0
}

write_file() {  # <dest> <mode>; content on stdin
  local dest=$1 mode=$2 tmp
  tmp=$(mktemp "${dest%/*}/.${dest##*/}.XXXXXX") || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
}

cmd=${1:-}
case "$cmd" in
  --help|-h) help_text; exit 0 ;;
  install) shift ;;
  *) usage ;;
esac

dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skills-dir)
      [ "$#" -ge 2 ] || usage
      dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$dir" in
  /*) dir=${dir%/} ;;
  *) printf '%s\n' 'error: --skills-dir must be an absolute path' >&2; exit 2 ;;
esac
if [ -n "${HOME:-}" ]; then
  case "$dir/" in
    "$HOME/.hermes/"*)
      if [ "${FM_HERMES_SKILL_ALLOW_LIVE:-}" != 1 ]; then
        printf '%s\n' 'error: refusing to write a live Hermes directory without FM_HERMES_SKILL_ALLOW_LIVE=1' >&2
        exit 2
      fi
      ;;
  esac
fi

home=${FM_HOME:-}
case "$home" in
  /*) home=${home%/} ;;
  *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
esac
[ -d "$home" ] && [ ! -L "$home" ] || { printf '%s\n' 'error: FM_HOME must be a directory, not a symlink' >&2; exit 2; }
pin_ok "$home" || { printf '%s\n' 'error: FM_HOME is not a path the skill entry accepts' >&2; exit 2; }
pin_ok "$ROOT" || { printf '%s\n' 'error: this checkout is not a path the skill entry accepts' >&2; exit 2; }
[ -f "$ROOT/hermes/firstmate-inbox/SKILL.md" ] && [ -f "$SCRIPT_DIR/fm-hermes-inbox-entry.sh" ] || {
  printf '%s\n' 'error: the skill sources are missing from this checkout' >&2
  exit 2
}

skill=$dir/firstmate-inbox
mkdir -p "$skill/scripts" || exit 1
write_file "$skill/SKILL.md" 644 < "$ROOT/hermes/firstmate-inbox/SKILL.md" || exit 1
write_file "$skill/scripts/firstmate-inbox.sh" 755 < "$SCRIPT_DIR/fm-hermes-inbox-entry.sh" || exit 1
printf '%s\n' "$ROOT" | write_file "$skill/firstmate-root" 644 || exit 1
printf '%s\n' "$home" | write_file "$skill/fm-home" 644 || exit 1
printf 'installed %s\n' "$skill"
