#!/usr/bin/env bash
# tests/fm-broken-session-lib.test.sh - broken model session detection and relaunch
# bookkeeping owned by bin/fm-broken-session-lib.sh and driven from bin/fm-watch.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
LIB=$ROOT/bin/fm-broken-session-lib.sh
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-broken-session-lib)

# shellcheck source=bin/fm-broken-session-lib.sh
. "$LIB"

test_capture_matches_documented_api_error_banners() {
  fm_broken_session_capture_matches $'line\nAPI Error: response stopped arriving\n' \
    || fail 'API Error banner must match'
  fm_broken_session_capture_matches 'Named models unavailable on this plan' \
    || fail 'Named models unavailable must match'
  fm_broken_session_capture_matches 'Provider error (503): upstream refused' \
    || fail 'Provider error prefix must match'
  fm_broken_session_capture_matches 'Content generator not initialized' \
    || fail 'Gemini generator banner must match'
  pass 'capture matcher accepts documented API error banners'
}

test_capture_rejects_ordinary_idle_pane_text() {
  fm_broken_session_capture_matches '✻ Working…' && fail 'busy spinner must not match'
  fm_broken_session_capture_matches 'done: ready in branch fm/foo' && fail 'status text must not match'
  pass 'capture matcher rejects ordinary pane text'
}

test_recent_attempts_resets_after_rearmed() {
  local dir=$TMP_ROOT/ledger state=$TMP_ROOT/ledger/state id=t1
  mkdir -p "$state"
  fm_broken_session_ledger_add "$state" "$id" attempt || fail 'ledger append failed'
  fm_broken_session_ledger_add "$state" "$id" attempt || fail 'ledger append failed'
  [ "$(fm_broken_session_recent_attempts "$state" "$id" 3600)" -eq 2 ] \
    || fail 'expected two attempts before rearmed'
  fm_broken_session_ledger_add "$state" "$id" rearmed || fail 'rearmed row failed'
  fm_broken_session_ledger_add "$state" "$id" attempt || fail 'post-rearmed attempt failed'
  [ "$(fm_broken_session_recent_attempts "$state" "$id" 3600)" -eq 1 ] \
    || fail 'rearmed row must reset the attempt window'
  pass 'attempt counter resets after a rearmed ledger row'
}

make_broken_probe_case() {
  local name=$1 pane_text=$2
  local dir=$TMP_ROOT/$name fakebin state meta capture
  dir=$TMP_ROOT/$name
  fakebin=$(fm_fakebin "$dir")
  state=$dir/state
  capture=$dir/pane.txt
  mkdir -p "$state"
  printf '%s\n' "$pane_text" > "$capture"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  capture-pane) cat '$capture'; exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_current_command*) printf 'claude\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows) printf 'win\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf 'window=ses:win\nkind=ship\nharness=claude\nbackend=tmux\n' > "$state/ship1.meta"
  PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-busy-event.sh" arm "$state" ship1 --state idle --source claude-hook --event stop-failure \
    >/dev/null || return 1
  printf '%s\n' "$fakebin" "$state"
}

test_probe_marks_idle_alive_api_error_as_broken() {
  local fakebin state out
  out=$(make_broken_probe_case probe-broken $'✻ Idle\nAPI Error: token limit\n') \
    || fail 'probe fixture setup failed'
  fakebin=${out%%$'\n'*}
  state=${out#*$'\n'}
  PATH="$fakebin:$BASE_PATH" FM_HOME="${state%/state}" FM_STATE_OVERRIDE=$state \
    fm_broken_session_probe "$state" "$state/ship1.meta" ship1
  [ "$FM_BROKEN_STATUS" = broken ] \
    || fail "expected broken, got $FM_BROKEN_STATUS (${FM_BROKEN_DETAIL:-})"
  pass 'probe marks an idle alive worker with a visible API error as broken'
}

test_probe_skips_busy_pane_with_error_banner() {
  local fakebin state out
  out=$(make_broken_probe_case probe-busy $'✻ Working…\nAPI Error: token limit\n') \
    || fail 'probe fixture setup failed'
  fakebin=${out%%$'\n'*}
  state=${out#*$'\n'}
  PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-busy-event.sh" apply "$state" ship1 busy --current-gen \
    --source claude-hook --event user-prompt >/dev/null \
    || fail 'could not mark busy'
  PATH="$fakebin:$BASE_PATH" FM_HOME="${state%/state}" FM_STATE_OVERRIDE=$state \
    fm_broken_session_probe "$state" "$state/ship1.meta" ship1
  [ "$FM_BROKEN_STATUS" = skip ] \
    || fail "busy worker must not be broken-session relaunchable, got $FM_BROKEN_STATUS"
  pass 'probe skips a busy worker even when an error banner is visible'
}

test_capture_matches_documented_api_error_banners
test_capture_rejects_ordinary_idle_pane_text
test_recent_attempts_resets_after_rearmed
test_probe_marks_idle_alive_api_error_as_broken
test_probe_skips_busy_pane_with_error_banner
