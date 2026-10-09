#!/usr/bin/env bash
# Live guard for the one fact bin/fm-grok-trust.sh turns on: WHICH folder key
# suppresses Grok's directory-security dialog for a launch inside a LINKED
# worktree.
#
# tests/fm-grok-trust.test.sh pins the helper's chosen contract portably, but no
# assertion over a TOML file can observe the dialog, so a future grok that keys
# trust differently would leave that suite green while every crewmate spawn
# wedged on an unanswerable prompt again. This guard is the only thing that can
# catch that: it launches the real binary three times against three throwaway
# Grok homes and reads the dialog off the pane.
#
#   arm                 store seeded with            expected
#   control             nothing                      dialog FIRES
#   worktree-key-only   the launch worktree path     dialog FIRES
#   main-root-key-only  bin/fm-grok-trust.sh's key   dialog SUPPRESSED
#
# The third arm seeds through the helper itself rather than by hand, so this is
# also the end-to-end proof of the fix: the key the helper writes is the key the
# binary reads.
#
# Two confounds are closed rather than assumed. Each arm gets a FRESH store
# holding at most one key, so no arm can be rescued by a grant another arm left
# behind. And bin/fm-spawn.sh does not forward GROK_HOME onto the launch, so the
# seeding process and the launched pane could in principle resolve different
# stores; this reads the launched grok process's own /proc/<pid>/environ and
# requires the value to be the home this arm seeded.
#
# It submits no prompts and spends no model tokens, so it is default-on: it runs
# wherever grok is installed. It does need credentials to get past the sign-in
# screen to the dialog, and says so rather than passing quietly when they or
# /proc are absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_GROK_TRUST_LIVE_E2E grok tmux

TRUST="$ROOT/bin/fm-grok-trust.sh"
GROK_VERSION=$(grok --version 2>/dev/null || echo 'grok (version unknown)')
DIALOG='Do you trust the contents of this directory?'
COMPOSER='❯'
WAIT_ATTEMPTS=${FM_GROK_TRUST_LIVE_ATTEMPTS:-120} # half-second polls

# fm_live_gate has already exited for an explicit opt-out, so anything still
# missing here is a capability this host lacks. Naming it keeps an absent
# prerequisite visible in the runner instead of reading as a pass, and a guard
# that was explicitly requested fails on it rather than skipping.
live_requested() {
  case "${FM_GROK_TRUST_LIVE_E2E:-}" in
    1) return 0 ;;
  esac
  [ "${FM_LIVE:-}" = 1 ]
}

capability_skip() { # <reason>
  if live_requested; then
    fail "$GROK_VERSION guard was requested but $1"
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}

[ -r /proc/self/environ ] ||
  capability_skip 'no readable /proc, so the launched pane cannot be proven to read the seeded store'

AUTH=${FM_GROK_AUTH_FILE:-$HOME/.grok/auth.json}
[ -f "$AUTH" ] && [ -r "$AUTH" ] ||
  capability_skip "grok credentials absent (set FM_GROK_AUTH_FILE; looked at $AUTH)"

TMP_ROOT=$(fm_test_tmproot fm-grok-trust-live) || fail 'could not create a fixture root'
TMUX=$(command -v tmux)
SOCKETS=()

kill_sockets() {
  local socket
  for socket in "${SOCKETS[@]:-}"; do
    [ -n "$socket" ] && "$TMUX" -L "$socket" kill-server 2>/dev/null
  done
  SOCKETS=()
}

cleanup() {
  kill_sockets
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# The dialog is raised only for a workspace carrying trust-relevant surfaces: a
# bare repository with one text file does not raise it. Commit the surfaces
# before the worktree is added so both the main root and the linked worktree
# carry them, exactly like a real firstmate task worktree.
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
fm_git_init_commit "$PROJ"
mkdir -p "$PROJ/.grok"
printf '# Project instructions\n\nNothing to do.\n' > "$PROJ/AGENTS.md"
printf '{\n  "hooks": {}\n}\n' > "$PROJ/.grok/settings.json"
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'trust-relevant surfaces'
git -C "$PROJ" worktree add --quiet -b grok-trust-live "$WT"

PROJ_REAL=$(cd -P -- "$PROJ" && pwd -P)
WT_REAL=$(cd -P -- "$WT" && pwd -P)

# A throwaway Grok home holding nothing but a COPY of the credential. A copy,
# not a link, so a refresh inside the sandbox can never reach the real one.
make_home() { # <arm>
  local home="$TMP_ROOT/home-$1"
  mkdir -p "$home"
  chmod 700 "$home"
  cp "$AUTH" "$home/auth.json"
  chmod 600 "$home/auth.json"
  printf '%s\n' "$home"
}

seed_key() { # <home> <path>
  local store="$1/trusted_folders.toml"
  printf '[folders."%s"]\ntrusted = true\ndecided_at = %s\n' "$2" "$(date +%s)" > "$store"
  chmod 600 "$store"
}

granted_paths() { # <home>
  python3 - "$1/trusted_folders.toml" <<'PY'
import pathlib, sys, tomllib
store = pathlib.Path(sys.argv[1])
if not store.exists():
    raise SystemExit(0)
for key, value in (tomllib.loads(store.read_text("utf-8")).get("folders") or {}).items():
    if isinstance(value, dict) and value.get("trusted") is True:
        print(key)
PY
}

capture() { # <socket>
  "$TMUX" -L "$1" capture-pane -p -t grok-trust 2>/dev/null || true
}

# The grok process under the pane's shell, once it exists. Its own environment
# is what proves the store this arm seeded is the store the binary reads.
launched_grok_pid() { # <socket>
  local socket=$1 pane_pid child i=0
  while [ "$i" -lt "$WAIT_ATTEMPTS" ]; do
    pane_pid=$("$TMUX" -L "$socket" display-message -p -t grok-trust '#{pane_pid}' 2>/dev/null || true)
    if [ -n "$pane_pid" ]; then
      for child in $(pgrep -P "$pane_pid" 2>/dev/null); do
        case $(tr '\0' ' ' < "/proc/$child/cmdline" 2>/dev/null) in
          *grok*)
            printf '%s\n' "$child"
            return 0
            ;;
        esac
      done
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

grok_home_of() { # <pid>
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^GROK_HOME=//p'
}

# run_arm <arm> <home> <expect: fires|suppressed>
run_arm() {
  local arm=$1 home=$2 expect=$3 socket pid seen_home pane i=0
  socket="fm-grok-trust-live-$$-$arm"
  SOCKETS+=("$socket")
  "$TMUX" -L "$socket" new-session -d -x 140 -y 45 -s grok-trust -c "$WT_REAL" \
    "env GROK_HOME='$home' grok --no-alt-screen; sleep 600" ||
    fail "$GROK_VERSION: the $arm arm could not be launched"

  pid=$(launched_grok_pid "$socket") ||
    fail "$GROK_VERSION: the $arm arm never started a grok process"
  seen_home=$(grok_home_of "$pid")
  [ "$seen_home" = "$home" ] ||
    fail "$GROK_VERSION: the $arm arm's grok read GROK_HOME='$seen_home', not the seeded '$home', so this arm proves nothing"

  while [ "$i" -lt "$WAIT_ATTEMPTS" ]; do
    pane=$(capture "$socket")
    case $pane in
      *"$DIALOG"*)
        [ "$expect" = fires ] ||
          fail "$GROK_VERSION: trusting the repository main root no longer suppresses the directory-security dialog; bin/fm-grok-trust.sh registers a key grok no longer reads"
        "$TMUX" -L "$socket" kill-server 2>/dev/null
        pass "fm-grok-trust live: $arm -> the directory-security dialog fires"
        return 0
        ;;
      *"$COMPOSER"*)
        [ "$expect" = suppressed ] ||
          fail "$GROK_VERSION: the $arm arm reached the composer with no dialog; grok's keying model has changed and bin/fm-grok-trust.sh must be re-derived"
        "$TMUX" -L "$socket" kill-server 2>/dev/null
        pass "fm-grok-trust live: $arm -> no dialog; grok reached its composer"
        return 0
        ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done

  capture "$socket" >&2
  fail "$GROK_VERSION: the $arm arm reached neither the dialog nor the composer"
}

CONTROL_HOME=$(make_home control)
run_arm control "$CONTROL_HOME" fires

WT_HOME=$(make_home worktree-key)
seed_key "$WT_HOME" "$WT_REAL"
run_arm worktree-key "$WT_HOME" fires

ROOT_HOME=$(make_home main-root-key)
TRUST_OUT=$(GROK_HOME="$ROOT_HOME" "$TRUST" "$WT_REAL" "$PROJ_REAL" 2>&1) ||
  fail "bin/fm-grok-trust.sh refused a legitimate task worktree: $TRUST_OUT"
GRANTED=$(granted_paths "$ROOT_HOME")
assert_equals "$PROJ_REAL" "$GRANTED" \
  "the helper must grant the repository main root and nothing else, got: $GRANTED"
run_arm main-root-key "$ROOT_HOME" suppressed

pass "fm-grok-trust live: $GROK_VERSION keys folder trust on the repository main worktree, and the helper writes that key"
