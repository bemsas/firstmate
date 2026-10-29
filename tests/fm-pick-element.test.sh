#!/usr/bin/env bash
# Behavior tests for fm-pick-element.sh: capture artifacts and steer via fm-send.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

PICK="$ROOT/bin/fm-pick-element.sh"
TMP_ROOT=$(fm_test_tmproot fm-pick-element)

make_cdt_fake() { # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  run)
    printf '%s\n' '{"cancelled":false,"url":"http://example.test/app","selector":"h1.title","tag":"h1","text":"Hello","outerHTML":"<h1 class=\"title\">Hello</h1>","viewport":{"width":1280,"height":720}}'
    ;;
  screenshot)
    printf 'ok\n' >"$2"
    ;;
  snapshot)
    printf 'snapshot-stub\n'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/chrome-devtools-axi"
}

make_tmux_fake() { # <dir>
  local fb="$1/fakebin"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) printf 'fm-worker\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

setup_home() { # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data"
  make_cdt_fake "$dir"
  make_tmux_fake "$dir"
  fm_write_meta "$dir/home/state/worker.meta" "window=sess:fm-worker" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

inbox_body() { # <record>
  fm_task_inbox_body "$1"
}

test_send_selector_delivers() {
  local dir err rc pick_dir body rec
  dir=$(setup_home send-selector)
  err="$dir/err.log"
  RC=0
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$PICK" send worker --selector 'h1.title' --comment 'tone this down' >"$dir/out" 2>"$err" || RC=$?
  expect_code 0 "$RC" "send"
  assert_contains "$(cat "$dir/out")" 'delivered: task=worker' "send reported delivery"
  pick_dir=$(find "$dir/home/data/worker/pick" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$pick_dir" ] || fail "artifact directory missing"
  [ -f "$pick_dir/dom.txt" ] || fail "dom.txt missing"
  grep -F 'class="title"' "$pick_dir/dom.txt" >/dev/null || fail "dom excerpt missing"
  [ -f "$pick_dir/screenshot.png" ] || fail "screenshot missing"
  [ -f "$pick_dir/manifest.json" ] || fail "manifest missing"
  assert_contains "$(cat "$pick_dir/manifest.json")" '"schema":"fm-pick-element.v1"' "manifest schema"
  rec="$dir/home/state/worker.inbox/001.msg"
  [ -f "$rec" ] || fail "inbox record missing"
  body=$(inbox_body "$rec")
  assert_contains "$body" 'Captain element feedback (fm-pick-element.v1)' "steer header"
  assert_contains "$body" "$pick_dir/manifest.json" "steer cites manifest"
  assert_contains "$body" 'tone this down' "steer carries comment"
  pass "send --selector writes artifacts and steers through fm-send"
}

test_unknown_task_refused() {
  local dir err
  dir=$(setup_home unknown)
  err="$dir/err.log"
  RC=0
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$PICK" send missing-task --selector h1 >"$dir/out" 2>"$err" || RC=$?
  expect_code 1 "$RC" "unknown task"
  assert_contains "$(cat "$err")" 'unknown task' "error names missing task"
  pass "unknown task is refused before capture"
}

test_send_selector_delivers
test_unknown_task_refused
